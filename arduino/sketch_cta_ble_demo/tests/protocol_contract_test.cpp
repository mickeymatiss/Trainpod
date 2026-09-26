#include "../src/products/transit/data/ArrivalPayload.h"
#include "../src/platform/transport/PayloadDelivery.h"
#include <cassert>
#include <fstream>
#include <sstream>
#include <iterator>
#include <vector>
#include <iostream>
static std::string read(const std::string& p) {std::ifstream f(p,std::ios::binary);assert(f.good());return {std::istreambuf_iterator<char>(f),{}};}
static std::string signature(const ArrivalBoard& b) {
 std::ostringstream s;s<<b.platformCount;
 for(const auto& p:b.platforms) {s<<'|'<<p.stationName<<'|'<<p.direction<<'|'<<p.distanceValue<<'|'<<p.distanceUnit<<'|'<<p.arrivalCount;for(const auto& a:p.arrivals)s<<'|'<<a.routeLabel<<'|'<<a.routeColor<<'|'<<a.destination<<'|'<<a.eta;}
 return s.str();
}
int main(int argc,char** argv) {
 assert(argc==2);const std::string dir=argv[1];std::istringstream index(read(dir+"/index.tsv"));std::string line;
 ArrivalBoard retained;assert(decodeArrivalPayload(read(dir+"/cta.tp2"),retained)==ArrivalPayloadResult::valid);
 while(std::getline(index,line)) {
  std::istringstream row(line);std::string name,status,counts;std::getline(row,name,'\t');std::getline(row,status,'\t');std::getline(row,counts);
  const auto before=signature(retained);auto result=decodeArrivalPayload(read(dir+"/"+name+".tp2"),retained);
  if(status=="valid") {
   assert(result==ArrivalPayloadResult::valid);std::istringstream cs(counts);std::string count;size_t i=0;
   while(std::getline(cs,count,',')){assert(retained.platforms[i++].arrivalCount==std::stoul(count));}assert(retained.platformCount==i);
   if(name=="long_names")assert(retained.platforms[0].stationName.size()==48 && retained.platforms[0].direction=="N. East" && retained.platforms[0].arrivals[0].routeLabel.size()==20);
   if(name=="identity") {ArrivalScreenState s;s.setBoard(retained,0);s.setBoard(retained,1);assert(s.platform==1);s.nextStation(2);assert(s.platform==1);} // Current duplicate-display-identity behavior, not a recommendation.
  } else {assert(result==(status=="invalid"?ArrivalPayloadResult::invalid:ArrivalPayloadResult::unavailable));assert(signature(retained)==before);}
 }
 const auto payload=read(dir+"/cta.tp2"), raw=read(dir+"/cta.header");
 std::vector<uint8_t> header(raw.begin(),raw.end());PayloadDelivery::Frame frame;
 assert(frame.begin(header.data(),header.size(),123));assert(frame.tx==0x1234567800000007ULL && frame.started==123);
 for(size_t offset=0;offset<payload.size();offset+=20)assert(frame.accept(reinterpret_cast<const uint8_t*>(payload.data()+offset),std::min(size_t(20),payload.size()-offset)));
 assert(frame.ready && !frame.active && frame.bytes==payload.size());assert(std::string(reinterpret_cast<char*>(frame.data),frame.bytes)==payload);
 assert(!frame.accept(reinterpret_cast<const uint8_t*>(payload.data()),1));
 auto original=header;
 for(unsigned length:{0u,2049u}) {header=original;PayloadDelivery::put16(header.data()+11,length);assert(!frame.begin(header.data(),header.size(),0));}
 for(unsigned chunks:{0u,unsigned(payload.size()+1)}) {header=original;PayloadDelivery::put16(header.data()+13,chunks);assert(!frame.begin(header.data(),header.size(),0));}
 header=original;assert(!frame.begin(header.data(),18,0));header[2]=1;assert(!frame.begin(header.data(),19,0));
 header=original;PayloadDelivery::put16(header.data()+13,1);assert(frame.begin(header.data(),19,0));
 assert(!frame.accept(reinterpret_cast<const uint8_t*>(payload.data()),payload.size()-1) && frame.error==PayloadDelivery::Frame::LengthMismatch);
 assert(frame.begin(original.data(),19,0));assert(!frame.accept(nullptr,0));
 header=original;PayloadDelivery::put16(header.data()+13,1);header[15]^=1;assert(frame.begin(header.data(),19,0));
 assert(!frame.accept(reinterpret_cast<const uint8_t*>(payload.data()),payload.size()) && frame.error==PayloadDelivery::Frame::Checksum);
 assert(frame.begin(original.data(),19,0));assert(frame.accept(reinterpret_cast<const uint8_t*>(payload.data()),20));frame.reset();
 assert(!frame.ready && !frame.active && frame.tx==0 && frame.bytes==0);
 // Maximum transport capacity, independent of TP2 syntax.
 std::string maximum(2048,'x');header=original;PayloadDelivery::put16(header.data()+11,2048);PayloadDelivery::put16(header.data()+13,2);PayloadDelivery::put32(header.data()+15,PayloadDelivery::crc32(reinterpret_cast<const uint8_t*>(maximum.data()),maximum.size()));
 assert(frame.begin(header.data(),19,9));assert(frame.accept(reinterpret_cast<const uint8_t*>(maximum.data()),1024));assert(frame.accept(reinterpret_cast<const uint8_t*>(maximum.data()+1024),1024));assert(frame.ready && frame.data[2048]==0);
 assert(PayloadDelivery::crc32(reinterpret_cast<const uint8_t*>("123456789"),9)==0xcbf43926);
 std::cout<<"PASS shared TP2/header goldens, atomic rejection, display identity, frame limits/count/CRC/reset/recovery\n";
}
