// Zapret.app — нативное приложение управления обходом DPI для macOS.
//
// Архитектура:
//   * Привилегированный backend остаётся на shell-скриптах в /opt/zapret/mac
//     (start/stop/status/strategy/selftest/update), вызываемых без пароля через
//     `sudo -n` (правило в /etc/sudoers.d/zapret кладёт install.sh).
//   * Этот Swift-фронтенд — нативное окно (с кнопками-светофором) + иконка в
//     меню-баре (трей). Установка/удаление требуют пароль (osascript admin).
//
// Сборка: build-app.sh → swiftc -parse-as-library -swift-version 5 ...
//
// Принципы:
//   * Длинные операции (тест стратегий, обновление списков) НЕ блокируют UI:
//     стримим вывод скрипта в лог-панель построчно.
//   * Закрытие окна (красная кнопка) прячет окно, приложение живёт в трее —
//     как у Happ. Полный выход — пункт «Выход» в меню-баре.

import AppKit
import SwiftUI

// MARK: - Пресеты стратегий (синхронизировано с strategy.sh)

struct Strategy: Identifiable, Hashable {
    let id: String
    let title: String
    var name: String { id }
}

let kStrategies: [Strategy] = [
    Strategy(id: "default",    title: "Сплит SNI + disorder — рекомендуется"),
    Strategy(id: "split-only", title: "Только сплит — если default рвёт соединения"),
    Strategy(id: "midsld",     title: "Сплит по середине домена + disorder"),
    Strategy(id: "oob",        title: "Сплит + out-of-band — против въедливых DPI"),
    Strategy(id: "hostcase",   title: "Искажение Host + сплит — запасной вариант"),
]

let kInstallDir = "/opt/zapret"
let kMacDir = "/opt/zapret/mac"
let kAppVersion = "2.0.1"
let kRepo = "glalker/Zapret-mac-m2-git"

// MARK: - Запуск процессов

@discardableResult
func runCapture(_ path: String, _ args: [String]) -> (out: String, code: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return ("\(error)", -1) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
}

// MARK: - Контроллер состояния

final class Controller: ObservableObject {
    @Published var running = false
    @Published var paused = false
    @Published var installed = false
    @Published var vpnActive = false
    @Published var strategy = "default"
    @Published var busy = false
    @Published var busyTitle = ""
    @Published var log = ""
    @Published var showLog = false

    private var pollTimer: Timer?
    private var streamProc: Process?

    weak var delegate: AppDelegate?

    init() {
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // Состояние читается без прав root.
    func refresh() {
        let isRunning = runCapture("/usr/bin/pgrep", ["-x", "tpws"]).code == 0
        let isInstalled = FileManager.default.fileExists(atPath: "\(kMacDir)/start.sh")
        let isPaused = FileManager.default.fileExists(atPath: "/var/run/zapret.paused-by-vpn")
        var strat = "default"
        if let s = try? String(contentsOfFile: "\(kMacDir)/.strategy", encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { strat = t }
        }
        let vpn = detectVPN()
        DispatchQueue.main.async {
            self.running = isRunning
            self.installed = isInstalled
            self.paused = isPaused && !isRunning
            self.strategy = strat
            self.vpnActive = vpn
            self.delegate?.refreshMenuBar()
        }
    }

    private func detectVPN() -> Bool {
        // 1. Системные VPN-профили.
        let nc = runCapture("/usr/sbin/scutil", ["--nc", "list"]).out
        if nc.contains("(Connected)") { return true }
        // 2. Дефолтный маршрут через туннель.
        let r = runCapture("/sbin/route", ["-n", "get", "default"]).out
        for line in r.split(separator: "\n") where line.contains("interface:") {
            let ifc = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? ""
            for p in ["utun", "ipsec", "ppp", "tun", "tap", "wg"] where ifc.hasPrefix(p) {
                return true
            }
        }
        return false
    }

    var statusText: String {
        if running { return "Обход включён" }
        if paused { return "На паузе — обнаружен VPN" }
        if !installed { return "Не установлен" }
        return "Обход выключен"
    }

    var isActive: Bool { running || paused }

    // MARK: Действия (sudo -n, без пароля)

    func toggle() {
        guard installed else { reinstall(); return }
        let script = isActive ? "stop.sh" : "start.sh"
        let title = isActive ? "Выключаю обход…" : "Включаю обход…"
        runScriptSudo(script, title: title)
    }

    func setStrategy(_ name: String) {
        guard installed else { return }
        runScriptSudo("strategy.sh", args: ["set", name], title: "Меняю стратегию на «\(name)»…")
    }

    // Короткое привилегированное действие без стриминга.
    private func runScriptSudo(_ script: String, args: [String] = [], title: String) {
        busy = true; busyTitle = title
        DispatchQueue.global().async {
            let res = runCapture("/usr/bin/sudo", ["-n", "\(kMacDir)/\(script)"] + args)
            DispatchQueue.main.async {
                self.busy = false
                if res.code != 0 && res.out.contains("a password is required") {
                    self.alert("Нужно правило без пароля.\nНажми «Переустановить» — установщик его создаст.", warning: true)
                }
                self.refresh()
            }
        }
    }

    // MARK: Стриминговые действия (тест/обновление)

    func runAutotest() {
        guard installed else { return }
        streamScript("selftest.sh", title: "Подбираю стратегию…",
                     header: "🔬 Тестирую стратегии обхода на заблокированных сайтах.\nЭто займёт 1–2 минуты. tpws будет перезапускаться.\n")
    }

    func updateLists() {
        guard installed else { return }
        streamScript("update.sh", title: "Обновляю списки…",
                     header: "🔄 Скачиваю свежий список заблокированных доменов…\n")
    }

    private func streamScript(_ script: String, title: String, header: String) {
        busy = true; busyTitle = title; showLog = true; log = header
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        proc.arguments = ["-n", "\(kMacDir)/\(script)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.log += s }
        }
        proc.terminationHandler = { [weak self] _ in
            handle.readabilityHandler = nil
            DispatchQueue.main.async {
                self?.busy = false
                self?.log += "\n— Готово —\n"
                self?.refresh()
            }
        }
        do { try proc.run() } catch {
            busy = false
            log += "Ошибка запуска: \(error)\n"
            log += "Если просит пароль — нажми «Переустановить».\n"
        }
        streamProc = proc
    }

    // MARK: Открыть список «мои сайты»

    func editHosts() {
        let path = "\(kInstallDir)/ipset/zapret-hosts-user.txt"
        if FileManager.default.fileExists(atPath: path) {
            runCapture("/usr/bin/open", ["-a", "TextEdit", path])
            alert("Список открыт в TextEdit.\nДобавь домены над строкой «>>> AUTO», сохрани (Cmd+S), затем выключи и включи обход.", warning: false)
        } else {
            alert("zapret ещё не установлен.", warning: true)
        }
    }

    // MARK: Установка/удаление (нужен пароль)

    func reinstall() {
        busy = true; busyTitle = "Установка…"; showLog = true
        log = "⚙️ Запускаю установку. Введи пароль администратора в системном окне.\n"
        DispatchQueue.global().async {
            let scriptPath = self.installerPath()
            let cmd = "do shell script \"/bin/bash \\\"\(scriptPath)\\\" 2>&1\" with administrator privileges"
            let res = runCapture("/usr/bin/osascript", ["-e", cmd])
            DispatchQueue.main.async {
                self.busy = false
                self.log += res.out + "\n— Готово —\n"
                self.refresh()
            }
        }
    }

    func uninstall() {
        let a = NSAlert()
        a.messageText = "Удалить zapret полностью?"
        a.informativeText = "Будут сняты PF-правила, удалены сервисы, правило sudoers и папка /opt/zapret."
        a.addButton(withTitle: "Удалить")
        a.addButton(withTitle: "Отмена")
        a.alertStyle = .warning
        guard a.runModal() == .alertFirstButtonReturn else { return }
        busy = true; busyTitle = "Удаление…"; showLog = true
        log = "🗑 Удаляю. Введи пароль администратора.\n"
        DispatchQueue.global().async {
            let cmd = "do shell script \"/bin/bash \\\"\(kMacDir)/uninstall.sh\\\" 2>&1\" with administrator privileges"
            let res = runCapture("/usr/bin/osascript", ["-e", cmd])
            DispatchQueue.main.async {
                self.busy = false
                self.log += res.out + "\n— Готово —\n"
                self.refresh()
            }
        }
    }

    // MARK: Проверка и установка обновлений из релизов GitHub

    // Проверка версии — read-only, без пароля.
    func checkForUpdate() {
        busy = true; busyTitle = "Проверяю обновления…"
        DispatchQueue.global().async {
            let api = "https://api.github.com/repos/\(kRepo)/releases/latest"
            let res = runCapture("/usr/bin/curl", ["-fsSL", "-m", "15", api])
            let tag = Self.parseTag(res.out)
            DispatchQueue.main.async {
                self.busy = false
                self.handleVersion(tag)
            }
        }
    }

    // Достаём значение "tag_name" из JSON ответа GitHub.
    static func parseTag(_ json: String) -> String {
        guard let r = json.range(of: "\"tag_name\"") else { return "" }
        let after = json[r.upperBound...]
        guard let q1 = after.range(of: "\"") else { return "" }
        let rest = after[q1.upperBound...]
        guard let q2 = rest.range(of: "\"") else { return "" }
        return String(rest[..<q2.lowerBound])
    }

    // "2.0.1" → [2,0,1]; сравнение покомпонентно.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let norm: (String) -> [Int] = { s in
            s.trimmingCharacters(in: .whitespaces)
             .replacingOccurrences(of: "v", with: "")
             .split(whereSeparator: { $0 == "." || $0 == " " })
             .prefix(3).compactMap { Int($0) }
        }
        let pa = norm(a), pb = norm(b)
        for i in 0..<3 {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private func handleVersion(_ tag: String) {
        let clean = tag.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else {
            alert("Не удалось проверить обновления.\nПроверь интернет (или включи обход, если GitHub режут).", warning: true)
            return
        }
        if Self.isNewer(clean, than: kAppVersion) {
            let a = NSAlert()
            a.messageText = "Доступна новая версия \(clean)"
            a.informativeText = "У тебя v\(kAppVersion). Скачать и установить \(clean)?\nПонадобится пароль администратора."
            a.addButton(withTitle: "Обновить")
            a.addButton(withTitle: "Позже")
            if a.runModal() == .alertFirstButtonReturn { runUpdate(clean) }
        } else {
            alert("У тебя последняя версия (v\(kAppVersion)).", warning: false)
        }
    }

    private func runUpdate(_ tag: String) {
        busy = true; busyTitle = "Обновляю до \(tag)…"; showLog = true
        log = "⬇️ Скачиваю и устанавливаю \(tag). Введи пароль администратора в системном окне.\n"
        DispatchQueue.global().async {
            let script = self.updaterPath()
            let cmd = "do shell script \"/bin/bash \\\"\(script)\\\" \(tag) 2>&1\" with administrator privileges"
            let res = runCapture("/usr/bin/osascript", ["-e", cmd])
            DispatchQueue.main.async {
                self.busy = false
                self.log += res.out + "\n— Готово —\n"
                self.refresh()
                if res.code == 0 { self.offerRelaunch(tag) }
            }
        }
    }

    private func offerRelaunch(_ tag: String) {
        let a = NSAlert()
        a.messageText = "Обновление \(tag) установлено"
        a.informativeText = "Перезапустить Zapret, чтобы применить новую версию?"
        a.addButton(withTitle: "Перезапустить")
        a.addButton(withTitle: "Позже")
        if a.runModal() == .alertFirstButtonReturn {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 1; open -n /Applications/Zapret.app"]
            try? p.run()
            NSApp.terminate(nil)
        }
    }

    // update-app.sh: сначала в бандле (есть всегда), потом в /opt/zapret/mac.
    private func updaterPath() -> String {
        if let res = Bundle.main.resourceURL?.appendingPathComponent("update-app.sh").path,
           FileManager.default.fileExists(atPath: res) {
            return res
        }
        return "\(kMacDir)/update-app.sh"
    }

    // install.sh: предпочитаем установленную копию (in-place), иначе рядом с .app.
    private func installerPath() -> String {
        if FileManager.default.fileExists(atPath: "\(kMacDir)/install.sh") {
            return "\(kMacDir)/install.sh"
        }
        let bundleMac = Bundle.main.bundleURL
            .deletingLastPathComponent().appendingPathComponent("install.sh").path
        return bundleMac
    }

    private func alert(_ msg: String, warning: Bool) {
        let a = NSAlert()
        a.messageText = warning ? "Внимание" : "Готово"
        a.informativeText = msg
        a.alertStyle = warning ? .warning : .informational
        a.runModal()
    }
}

// MARK: - SwiftUI: главный экран

struct ContentView: View {
    @ObservedObject var c: Controller

    var statusColor: Color {
        if c.running { return .green }
        if c.paused { return .orange }
        return Color(nsColor: .tertiaryLabelColor)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 18) {
                    powerCard
                    strategyCard
                    actionsCard
                    if c.showLog { logCard }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 440, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // Шапка
    var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Zapret").font(.system(size: 18, weight: .bold))
                Text("Обход блокировок DPI").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if c.vpnActive {
                Label("VPN", systemImage: "network.badge.shield.half.filled")
                    .font(.caption2).foregroundStyle(.orange)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.orange.opacity(0.12), in: Capsule())
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // Центральная карточка с большим тумблером
    var powerCard: some View {
        VStack(spacing: 16) {
            Button(action: { c.toggle() }) {
                ZStack {
                    Circle()
                        .fill(c.isActive ? statusColor.opacity(0.16) : Color(nsColor: .quaternaryLabelColor).opacity(0.4))
                        .frame(width: 132, height: 132)
                    Circle()
                        .stroke(c.isActive ? statusColor : Color(nsColor: .tertiaryLabelColor), lineWidth: 3)
                        .frame(width: 132, height: 132)
                    Image(systemName: "power")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundStyle(c.isActive ? statusColor : Color(nsColor: .tertiaryLabelColor))
                }
            }
            .buttonStyle(.plain)
            .disabled(c.busy || !c.installed)

            HStack(spacing: 7) {
                Circle().fill(statusColor).frame(width: 9, height: 9)
                Text(c.statusText).font(.system(size: 15, weight: .semibold))
            }
            if c.busy {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                    Text(c.busyTitle).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(c.installed ? "Нажми кнопку, чтобы \(c.isActive ? "выключить" : "включить")" : "Сначала установи zapret")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 22)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }

    // Карточка стратегии
    var strategyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Стратегия обхода", systemImage: "slider.horizontal.3")
                .font(.system(size: 13, weight: .semibold))
            Menu {
                ForEach(kStrategies) { s in
                    Button {
                        c.setStrategy(s.name)
                    } label: {
                        if s.name == c.strategy { Label(s.name, systemImage: "checkmark") }
                        else { Text(s.name) }
                    }
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.strategy).font(.system(size: 13, weight: .medium))
                        Text(kStrategies.first { $0.name == c.strategy }?.title ?? "")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .disabled(c.busy || !c.installed)
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))

            Button {
                c.runAutotest()
            } label: {
                Label("Подобрать автоматически", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(c.busy || !c.installed)
            Text("Прогонит тесты на заблокированных сайтах и выберет лучшую стратегию.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }

    // Прочие действия
    var actionsCard: some View {
        VStack(spacing: 10) {
            actionRow("Обновить списки сайтов", "arrow.down.circle", { c.updateLists() })
            actionRow("Мои сайты (ручной список)", "square.and.pencil", { c.editHosts() })
            actionRow("Проверить обновления приложения", "arrow.triangle.2.circlepath", { c.checkForUpdate() })
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }

    func actionRow(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon).frame(width: 22)
                Text(title).font(.system(size: 13))
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(c.busy || !c.installed)
    }

    // Лог-панель
    var logCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Журнал", systemImage: "text.alignleft").font(.caption.weight(.semibold))
                Spacer()
                Button { c.showLog = false } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(c.log.isEmpty ? "—" : c.log)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 150)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }

    // Подвал
    var footer: some View {
        HStack {
            Text("v\(kAppVersion)").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button("Переустановить") { c.reinstall() }
                .buttonStyle(.link).font(.caption).disabled(c.busy)
            Button("Удалить") { c.uninstall() }
                .buttonStyle(.link).font(.caption).foregroundStyle(.red).disabled(c.busy)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }
}

// MARK: - AppKit: окно + меню-бар

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let controller = Controller()
    var window: NSWindow!
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        controller.delegate = self
        buildWindow()
        buildStatusItem()
        showWindow(nil)
    }

    // Окно с нативными кнопками-светофором (titled+closable+miniaturizable+resizable).
    func buildWindow() {
        let host = NSHostingView(rootView: ContentView(c: controller))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Zapret"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.contentView = host
        window.center()
        window.delegate = self
        window.setFrameAutosaveName("ZapretMain")
        window.isReleasedWhenClosed = false
    }

    // Красная кнопка прячет окно — приложение продолжает жить в трее (как Happ).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        window.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    @objc func showWindow(_ sender: Any?) {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Меню-бар (трей)

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshMenuBar()
    }

    func refreshMenuBar() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        if controller.running { symbol = "shield.lefthalf.filled" }
        else if controller.paused { symbol = "shield.lefthalf.filled.slash" }
        else { symbol = "shield.slash" }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Zapret")
        img?.isTemplate = true
        button.image = img
    }

    // Меню строим заново при каждом открытии — всегда актуальное состояние.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: "Статус: \(controller.statusText)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        if controller.installed {
            let toggle = NSMenuItem(
                title: controller.isActive ? "Выключить обход" : "Включить обход",
                action: #selector(menuToggle), keyEquivalent: "")
            toggle.target = self
            menu.addItem(toggle)

            // Подменю стратегий
            let stratItem = NSMenuItem(title: "Стратегия", action: nil, keyEquivalent: "")
            let stratMenu = NSMenu()
            for s in kStrategies {
                let it = NSMenuItem(title: s.name, action: #selector(menuSetStrategy(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = s.name
                it.state = (s.name == controller.strategy) ? .on : .off
                stratMenu.addItem(it)
            }
            stratItem.submenu = stratMenu
            menu.addItem(stratItem)

            let test = NSMenuItem(title: "Подобрать стратегию автоматически",
                                  action: #selector(menuAutotest), keyEquivalent: "")
            test.target = self
            menu.addItem(test)

            let upd = NSMenuItem(title: "Обновить списки сайтов",
                                 action: #selector(menuUpdate), keyEquivalent: "")
            upd.target = self
            menu.addItem(upd)
        } else {
            let inst = NSMenuItem(title: "Установить zapret…", action: #selector(menuReinstall), keyEquivalent: "")
            inst.target = self
            menu.addItem(inst)
        }

        menu.addItem(.separator())
        let chk = NSMenuItem(title: "Проверить обновления…", action: #selector(menuCheckUpdate), keyEquivalent: "")
        chk.target = self
        menu.addItem(chk)
        let show = NSMenuItem(title: "Открыть окно Zapret", action: #selector(showWindow(_:)), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let quit = NSMenuItem(title: "Выход", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc func menuToggle() { controller.toggle() }
    @objc func menuAutotest() { showWindow(nil); controller.runAutotest() }
    @objc func menuUpdate() { showWindow(nil); controller.updateLists() }
    @objc func menuReinstall() { showWindow(nil); controller.reinstall() }
    @objc func menuCheckUpdate() { showWindow(nil); controller.checkForUpdate() }
    @objc func menuSetStrategy(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { controller.setStrategy(name) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

// MARK: - main

@main
struct ZapretMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
