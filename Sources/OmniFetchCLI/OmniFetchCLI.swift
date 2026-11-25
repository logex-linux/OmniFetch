import Darwin
import OmniFetchCore

@main
enum OmniFetchCLI {
    static func main() {
        exit(CommandLineTool.run(arguments: Array(CommandLine.arguments.dropFirst())))
    }
}
