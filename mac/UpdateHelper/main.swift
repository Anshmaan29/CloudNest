import CloudNestCore
import Foundation

@main struct CloudNestUpdateHelper {
  static func main() async {
    guard CommandLine.arguments.count == 3,
      ["--install-plan", "--rollback-plan"].contains(CommandLine.arguments[1])
    else { exit(64) }
    do {
      if CommandLine.arguments[1] == "--install-plan" {
        try await ReleaseUpdateInstaller.run(
          planURL: URL(fileURLWithPath: CommandLine.arguments[2]))
      } else {
        try await ReleaseUpdateInstaller.runRollback(
          planURL: URL(fileURLWithPath: CommandLine.arguments[2]))
      }
    } catch { exit(1) }
  }
}
