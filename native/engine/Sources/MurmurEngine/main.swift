import Foundation

var port: UInt16 = 18798
var watchStdin = true

var argv = Array(CommandLine.arguments.dropFirst())
while !argv.isEmpty {
    let a = argv.removeFirst()
    switch a {
    case "--port":
        if let v = argv.first, let p = UInt16(v) { port = p; argv.removeFirst() }
    case "--no-stdin-watch":
        watchStdin = false
    case "--help", "-h":
        print("usage: MurmurEngine [--port 18798] [--no-stdin-watch]")
        exit(0)
    default:
        break
    }
}

signal(SIGPIPE, SIG_IGN)

do {
    let server = EngineServer(port: port)
    try server.start()
    // Keep the server alive for the lifetime of the process.
    withExtendedLifetime(server) {}
    engine.warmUp()

    if watchStdin {
        // The Electron app owns our lifetime: when its end of the stdin pipe closes, exit.
        let t = Thread {
            var buf = [UInt8](repeating: 0, count: 256)
            while true {
                let n = read(0, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
            }
            elog("stdin closed, exiting")
            exit(0)
        }
        t.start()
    }
    dispatchMain()
} catch {
    elog("failed to start: \(error)")
    exit(1)
}
