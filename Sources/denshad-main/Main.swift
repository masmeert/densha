import DenshaDaemon

@main
struct DenshaDaemonExecutable {
    static func main() async {
        await DaemonRuntime.run()
    }
}
