import Foundation
import CryptoKit
// Manual companion for a focused, owned fixture field. No text is returned by
// the IME: compare its hash with the explicitly supplied fixture expectation.
guard CommandLine.arguments.count == 4 else { fatalError("Usage: RequestContextProbe <report.jsonl> <host-bundle> <expected-fixture-prefix>") }
let url = URL(fileURLWithPath:CommandLine.arguments[1])
let bundle = CommandLine.arguments[2], expected = CommandLine.arguments[3], token = UUID().uuidString
let expectedHash = SHA256.hash(data:Data(expected.utf8)).map { String(format:"%02x",$0) }.joined()
DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.fangcun.context-probe.sample"),object:nil,userInfo:["token":token,"bundle":bundle],deliverImmediately:true)
for _ in 0..<30 {
    RunLoop.current.run(until:Date().addingTimeInterval(0.1))
    let lines = (try? String(contentsOf:url,encoding:.utf8))?.split(separator:"\n") ?? []
    let rows = lines.compactMap { try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any] }.filter { $0["token"] as? String == token }
    if !rows.isEmpty {
        let result:[String:Any] = ["matchesFixture":rows.allSatisfy { $0["sha256"] as? String == expectedHash },"observations":rows]
        print(String(data:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),encoding:.utf8)!)
        exit(0)
    }
}
print("UNAVAILABLE: no active IME probe reply")
exit(2)
