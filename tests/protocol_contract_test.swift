import Foundation
struct Input: Decodable {
 let name: String; let stations: [Station]
 struct Station: Decodable { let id: String; let name: String; let distance: Double?; let platforms: [Platform] }
 struct Platform: Decodable { let id: String; let name: String; let trains: [Train] }
 struct Train: Decodable { let route: String; let destination: String; let minutes: Int; let displayName: String?; let displayColor: String? }
}
@main struct Contract {
 static func main() throws {
  let dir=URL(fileURLWithPath:CommandLine.arguments[1])
  let inputs=try JSONDecoder().decode([Input].self,from:Data(contentsOf:dir.appendingPathComponent("inputs.json")))
  for input in inputs {
   // Production payload() owns Date(). Mid-minute inputs give a 30s guard band;
   // an overloaded host fails the timing guard instead of silently shifting golden ETAs.
   let started=Date()
   let stations=input.stations.map { s in
    StationArrivals(station:CTAStation(id:s.id,name:s.name,latitude:41,longitude:-87,mapID:s.id,stopIDs:["p"]),directions:s.platforms.map { p in
     DirectionArrivals(id:p.id,name:p.name,trains:p.trains.enumerated().map { n,t in
      CTAArrival(id:String(n),route:t.route,destination:t.destination,arrivalTime:started.addingTimeInterval(Double(t.minutes*60)-30),approaching:false,delayed:false,stationName:s.name,stopDescription:p.name,directionID:p.id,routeDisplayName:t.displayName,routeDisplayColor:t.displayColor)
     })
    },distanceMeters:s.distance)
   }
   let actual=try LiveTransitFormatter.payload(from:stations)
   precondition(Date().timeIntervalSince(started)<10,"Host too slow for formatter clock guard")
   let expected=try Data(contentsOf:dir.appendingPathComponent(input.name+".tp2"))
   if actual != expected { try actual.write(to: URL(fileURLWithPath: "actual-"+input.name+".tp2")) }
   precondition(actual==expected,"Golden payload changed: \(input.name)")
   precondition(actual.count<=2048)
   if input.name=="near_limit" { precondition(actual.count>1800) }
  }
  let cta=try Data(contentsOf:dir.appendingPathComponent("cta.tp2"))
  let header=PayloadDelivery.header(.init(boot:0x12345678,request:7),payload:cta,chunks:(cta.count+19)/20)
  let golden=try Data(contentsOf:dir.appendingPathComponent("cta.header"));precondition(header==golden)
  for meters in [Double.nan, .infinity, -1] { precondition(LiveTransitFormatter.distanceLabel(meters).value.isEmpty) }
  precondition(LiveTransitFormatter.distanceLabel(0).value=="0")
  precondition(LiveTransitFormatter.distanceLabel(304.79).unit=="ft")
  precondition(LiveTransitFormatter.distanceLabel(304.8).unit=="mi")
  let now=Date(timeIntervalSince1970:1700000000)
  func arrival(_ seconds:Double)->CTAArrival { .init(id:String(seconds),route:"red",destination:"",arrivalTime:now.addingTimeInterval(seconds),approaching:false,delayed:false,stationName:"",stopDescription:"",directionID:"N") }
  precondition(LiveTransitFormatter.upcomingTrains([-1,60,120,180,1800,1801].map(arrival),at:now).map(\.id)==["60.0","120.0","180.0","1800.0"])
  precondition(LiveTransitFormatter.upcomingTrains([1900,2000,2100,2200].map(arrival),at:now).count==3)
  precondition(LiveTransitFormatter.stationLabel("Museum (West)")=="Museum (West)")
  precondition(LiveTransitFormatter.directionLabel("Clockwise")=="Clockwise")
  print("PASS six shared byte goldens, P1 header, size/truncation, agency/identity and distance/window boundaries")
 }
}
