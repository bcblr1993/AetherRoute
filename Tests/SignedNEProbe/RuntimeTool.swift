import Foundation

// Preparation/CI utility; does not execute the selected interpreter.
@main
struct RuntimeTool {
    static func main() {
        do {
            let arguments = CommandLine.arguments
            guard arguments.count == 3, arguments[1] == "inspect" else { throw SignedNEPythonRuntime.Failure.invalidRecord }
            let record = try SignedNEPythonRuntime.inspect(pythonPath: arguments[2])
            FileHandle.standardOutput.write(try record.encoded())
        } catch {
            FileHandle.standardError.write(Data("trusted-python-runtime-validation-failed\n".utf8))
            exit(1)
        }
    }
}
