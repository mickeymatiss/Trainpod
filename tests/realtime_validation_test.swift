import Foundation
@MainActor final class ControlledRealtime: RealtimeTransitFetching {
 var waiting:[TransitSystemID:CheckedContinuation<TransitRealtimeSnapshot,Error>]=[:]
 func fetchSnapshot(systemId:TransitSystemID) async throws -> TransitRealtimeSnapshot {try await withCheckedThrowingContinuation {waiting[systemId]=$0}}
}
@main struct RealtimeChecks {
 static func rejects(_ block:()throws->Void) {do {try block();preconditionFailure("Expected validation rejection")} catch {}}
 @MainActor static func main() async throws {
  let dir=URL(fileURLWithPath:CommandLine.arguments[1]);let bytes=try Data(contentsOf:dir.appendingPathComponent("cta.json"))
  let manifest=try JSONDecoder().decode(TransitSystemManifest.self,from:bytes)
  let original=try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
  func invalidManifest(_ edit:(inout [String:Any])->Void)throws {
   var value=original;edit(&value)
   let m=try JSONDecoder().decode(TransitSystemManifest.self,from:JSONSerialization.data(withJSONObject:value))
   rejects {try TransitManifestValidator.validate(m,expectedSystemID:.cta)}
  }
  try invalidManifest {$0["schemaVersion"]=2}
  try invalidManifest {$0["systemId"]="nyc"}
  try invalidManifest {$0["generatedAt"]="yesterday"}
  try invalidManifest {$0["routes"]=[String:String]()}
  try invalidManifest {var routes=$0["routes"] as! [String:[String:Any]];routes["R"]!["color"]="#nothex";$0["routes"]=routes}
  try invalidManifest {var stations=$0["stations"] as! [String:[String:Any]];stations["S"]!["latitude"]=91;$0["stations"]=stations}
  try invalidManifest {var stations=$0["stations"] as! [String:[String:Any]];var platforms=stations["S"]!["platforms"] as! [String:[String:Any]];platforms["P"]!["routeIds"]=["missing"];stations["S"]!["platforms"]=platforms;$0["stations"]=stations}
  try invalidManifest {var stations=$0["stations"] as! [String:[String:Any]];var second=stations["S"]!;second["id"]="T";stations["T"]=second;$0["stations"]=stations}
  let now=Date(timeIntervalSince1970:1700000000)
  func snapshot(_ system:String="cta",generated:Int64=1700000000,source:Int64=1700000000,schema:Int=1,stations:[String:TransitRealtimeStation]=[:])->TransitRealtimeSnapshot {.init(schemaVersion:schema,systemId:system,generatedAt:generated,sourceTimestamp:source,stations:stations)}
  try RealtimeResolver.validate(snapshot(),systemId:.cta,now:now)
  try RealtimeResolver.validate(snapshot(source:1699990000),systemId:.cta,now:now) // Old is inspectable, not automatically rejected here.
  precondition(snapshot(source:1699999820).sourceAge(at:now)==180)
  for invalid in [snapshot("nyc"),snapshot(generated:1700000061),snapshot(source:1700000061),snapshot(schema:2),snapshot(source:0)] {rejects{try RealtimeResolver.validate(invalid,systemId:.cta,now:now)}}
  func arrival(_ id:String,_ time:Int64=1700000060,route:String="R",destination:String?=nil)->TransitArrival {.init(routeId:route,tripId:id,arrivalAt:time,destinationStationId:destination)}
  let data=snapshot(stations:["S":.init(platforms:["P":.init(arrivals:[arrival("later",1700000120),arrival("first",destination:"unknown"),arrival("bad-route",route:"X"),arrival(""),arrival("far",1700086401)]),"unknown":.init(arrivals:[])]),"missing":.init(platforms:[:])])
  let resolved=try RealtimeResolver.resolve(snapshot:data,manifest:manifest)
  precondition(resolved.arrivals.map(\.tripId)==["first","later"])
  precondition(resolved.arrivals[0].direction=="North" && resolved.arrivals[0].routeColor=="#123456")
  precondition(resolved.diagnostics==["unknown_destination":1,"unknown_route":1,"invalid_arrival":2,"unknown_platform":1,"unknown_station":1])
  rejects{_ = try RealtimeResolver.resolve(snapshot:snapshot("nyc"),manifest:manifest)}
  // Existing protocol seam: complete the newer system first, then the obsolete response.
  let client=ControlledRealtime()
  let subject=RealtimeTransitService(client:client)
  let old=Task {await subject.refresh(systemId:.cta)}
  while client.waiting[.cta]==nil {await Task.yield()}
  let new=Task {await subject.refresh(systemId:.nyc)}
  while client.waiting[.nyc]==nil {await Task.yield()}
  client.waiting.removeValue(forKey:.nyc)!.resume(returning:snapshot("nyc"));await new.value
  client.waiting.removeValue(forKey:.cta)!.resume(returning:snapshot());await old.value
  precondition(subject.snapshot?.systemId=="nyc" && subject.lastError==nil)
  let failing=Task {await subject.refresh(systemId:.nyc)}
  while client.waiting[.nyc]==nil {await Task.yield()}
  client.waiting.removeValue(forKey:.nyc)!.resume(throwing:URLError(.notConnectedToInternet));await failing.value
  precondition(subject.snapshot?.systemId=="nyc" && subject.lastError != nil)
  print("PASS manifest malformed references, realtime timestamps/reference diagnostics, sorted results, obsolete generation rejection and retained snapshot on failure")
 }
}
