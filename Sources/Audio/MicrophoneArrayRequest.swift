import Foundation

// Keep VPIO in a separate process: its per-process device aliases would otherwise
// make the tracker's mic+speaker aggregate report duplicate input channels.
final class VoiceArrayMicrophones {
    private var process:Process?
    private var input:Pipe?
    private var errors:Pipe?
    private var exited:DispatchSemaphore?
    var active:Bool {process?.isRunning == true}
    func start(device _:UInt32) throws {
        stop()
        guard let executable=Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("EchoGesturesVoiceArray"),
              FileManager.default.isExecutableFile(atPath:executable.path) else {throw Failure.message("The microphone helper is missing.")}
        let task=Process(),stdin=Pipe(),stderr=Pipe(),done=DispatchSemaphore(value:0)
        task.executableURL=executable
        task.standardInput=stdin;task.standardOutput=FileHandle.nullDevice;task.standardError=stderr
        task.terminationHandler={ _ in done.signal() }
        try task.run()
        process=task;input=stdin;errors=stderr;exited=done
    }
    var failureDetail:String? {
        guard let process,!process.isRunning,let errors else {return nil}
        let data=errors.fileHandleForReading.readDataToEndOfFile()
        return String(data:data,encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines)
    }
    func stop(){
        guard let process else {return}
        try? input?.fileHandleForWriting.close()
        if process.isRunning,exited?.wait(timeout:.now()+1) == .timedOut {process.terminate()}
        self.process=nil;input=nil;errors=nil;exited=nil
    }
    deinit {stop()}
    private enum Failure:LocalizedError {case message(String);var errorDescription:String?{if case let .message(s)=self{return s};return nil}}
}
