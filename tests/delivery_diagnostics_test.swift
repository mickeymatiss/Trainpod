import Foundation
@main struct DeliveryDiagnosticsChecks {
 static func u32(_ v:UInt32)->[UInt8] { (0..<4).map { UInt8(truncatingIfNeeded:v >> ($0*8)) } }
 static func packet(_ kind:UInt8,_ body:[UInt8],id:UInt32=7)throws->DiagnosticPacket {try DiagnosticPacket(Data([0xd1,0xa6,1,kind]+u32(id)+body))}
 static func rejects(_ action:()throws->Void) { do {try action();preconditionFailure("Expected rejection")}catch{} }
 @MainActor static func main() throws {
  let tx=PayloadTransaction(boot:12,request:3)
  let req=Data([80,49,1]+u32(12)+u32(3));precondition(PayloadDelivery.request(req)==tx)
  for invalid in [Data(),req.dropLast(),Data([80,49,1]+u32(12)+u32(0)),req+Data([0])] {precondition(PayloadDelivery.request(invalid)==nil)}
  let ack=Data([80,49,3]+u32(12)+u32(3)+[0,42,0]);let decoded=PayloadDelivery.acknowledgement(ack)!
  precondition(decoded.0==tx && decoded.1==0 && decoded.2==42)
  precondition(PayloadDelivery.acknowledgement(ack.dropLast())==nil)
  let delivery=DeliveryAcknowledgements();var statuses:[String]=[]
  delivery.statusHandler={_,status in statuses.append(status)}
  delivery.begin(tx,bytes:42,session:"old")
  delivery.receive(tx,status:0,bytes:42,session:"new");precondition(statuses.isEmpty)
  delivery.receive(.init(boot:13,request:3),status:0,bytes:42,session:"old");precondition(statuses.isEmpty)
  delivery.receive(tx,status:0,bytes:42,session:"old");precondition(statuses.count==1 && statuses[0].contains("confirmed"))
  delivery.receive(tx,status:0,bytes:42,session:"old");precondition(statuses.count==1)
  delivery.transmissionCompleted(tx);precondition(statuses.count==1) // Already-applied ACK cannot become pending again.
  delivery.begin(tx,bytes:42,session:"new");delivery.receive(tx,status:0,bytes:41,session:"new");precondition(statuses.last!.contains("rejected"))
  let n=statuses.count;delivery.receive(tx,status:0,bytes:42,session:"new");precondition(statuses.count==n)
  delivery.begin(tx,bytes:42,session:"new");delivery.receive(tx,status:4,bytes:42,session:"new");precondition(statuses.count==n+1)
  delivery.begin(tx,bytes:42,session:"new");delivery.cancel(tx);delivery.receive(tx,status:0,bytes:42,session:"new");precondition(statuses.count==n+1)
  for id in 1...6 {delivery.begin(.init(boot:1,request:UInt32(id)),bytes:42,session:"new")}
  delivery.receive(.init(boot:1,request:1),status:0,bytes:42,session:"new");precondition(statuses.count==n+1)
  // Pure diagnostics envelope: completion requires all bytes, exact ID/order and valid CRC/UTF8.
  let bytes=Array("{\"version\":1}".utf8),crc=DiagnosticPacket.checksum(Data(bytes))
  func start()throws->DiagnosticAssembler {var a=DiagnosticAssembler();_ = try a.accept(packet(1,[1,0]+u32(UInt32(bytes.count))+u32(crc)));return a}
  var a=try start();precondition(!a.complete)
  _ = try a.accept(packet(2,u32(0)+Array(bytes.prefix(5))))
  _ = try a.accept(packet(2,u32(5)+Array(bytes.dropFirst(5))))
  let done=try a.accept(packet(3,u32(crc)));precondition(done==Data(bytes) && a.complete)
  rejects {_ = try a.accept(packet(3,u32(crc)))}
  rejects {var b=try start();_ = try b.accept(packet(2,u32(1)+bytes))}
  rejects {var b=try start();_ = try b.accept(packet(2,u32(0)+bytes,id:8))}
  rejects {var b=try start();_ = try b.accept(packet(3,u32(crc)))}
  rejects {var b=try start();_ = try b.accept(packet(2,u32(0)+bytes));_ = try b.accept(packet(3,u32(crc^1)))}
  rejects {var b=DiagnosticAssembler();_ = try b.accept(packet(1,[1,0]+u32(96001)+u32(0)))}
  rejects {_ = try packet(1,[],id:0)}
  rejects {_ = try DiagnosticPacket(Data([0xd1,0xa6,2,1]+u32(7)))}
  precondition(DiagnosticPacket.checksum(Data("123456789".utf8))==0xcbf43926)
  // Retained stage evidence and clock alignment, with no real clocks or device required.
  func event(_ sequence:Int,_ uptime:Int,_ code:String,_ sourceTime:Int?=nil)->[String:Any] {
   var row:[String:Any] = ["sequence":sequence,"uptimeMs":uptime,"sessionId":"session","eventCode":code,"level":"INFO","transactionId":"12-3"]
   if let sourceTime {row["unixTimeMs"]=sourceTime}
   return row
  }
  var sync=event(1,100,"TIME_SYNC_RECEIVED");sync["deviceUptimeMsAtSync"]=100;sync["phoneUnixTimeMs"]=1000
  let device:[String:Any] = ["metadata":["bootId":12],"deviceLogs":[sync,event(2,110,"DATA_REQUEST_SENT"),event(3,120,"DATA_APPLIED"),event(4,130,"DISPLAY_UPDATED")],"deviceErrors":[event(3,120,"DATA_APPLIED")]]
  let root:[String:Any] = ["device":device,"phoneLogs":[event(1,10,"DEVICE_DATA_REQUEST_RECEIVED",1010),event(2,20,"DATA_APPLIED_ACK_RECEIVED",1020)],"collectedAtUnixMs":4000]
  let normalized=DiagnosticInterleave.normalizedEvents(root)
  precondition(normalized.filter{$0.source=="DEVICE" && $0.code=="DATA_APPLIED"}.count==1)
  precondition(normalized.first{$0.code=="DISPLAY_UPDATED"}!.unix==1030)
  precondition(normalized.firstIndex{$0.code=="DATA_REQUEST_SENT"}! < normalized.firstIndex{$0.code=="DEVICE_DATA_REQUEST_RECEIVED"}!)
  let data=try JSONSerialization.data(withJSONObject:root,options:[.sortedKeys]);let rendered=try DiagnosticInterleave.render(data)
  precondition(rendered.contains("TRANSACTION 12-3 — SUCCESS"))
  let unchanged=try JSONSerialization.data(withJSONObject:root,options:[.sortedKeys]);precondition(data==unchanged)
  let unsynced=DiagnosticInterleave.normalizedEvents(["device":["deviceLogs":[event(1,1,"BOOT_START")]]])
  precondition(unsynced.count==1 && unsynced[0].unix==nil)
  let incomplete=try DiagnosticInterleave.render(JSONSerialization.data(withJSONObject:["device":["deviceLogs":[event(1,1,"FETCH_STARTED")]]]))
  precondition(incomplete.contains("NO COMPLETION EVENT"))
  print("PASS request/ACK wire checks, session/boot/length/status matching, duplicate/cancel/eviction, diagnostics assembly and timeline")
 }
}
