#include "../src/products/transit/ui/DisplayDirection.h"
#include <cassert>
#include <iostream>
#include <utility>
int main() {
  const std::pair<const char*,const char*> cases[] = {
    {"North","North"},{"South","South"},{"East","East"},{"West","West"},
    {"northBOUND","North"},{"SOUTHBOUND","South"},{"Eastbound","East"},{"westbound","West"},
    {"N.East","N. East"},{"N.West","N. West"},{"S.East","S. East"},{"S.West","S. West"},
    {"N. East","N. East"},{"N. West","N. West"},{"S. East","S. East"},{"S. West","S. West"},
    {"n.eAsT","N. East"},{"NORTHWEST","N. West"},{"southeastbound","S. East"},{"SouthWest","S. West"},
    {"North East","N. East"},{"North-West","N. West"},{"SOUTH EAST","S. East"},{"south-westbound","S. West"},
    {"Platform 3","3"},{"platform 3","platform 3"},{"Inbound","Inbound"},{"To Downtown","To Downtown"},
    {"Main East","East"},{"Northampton East","East"},{"NE","NE"},{"", ""}
  };
  for(const auto& item:cases) {
    const auto actual=TransitDisplay::displayDirection(item.first);
    if(actual!=item.second) { std::cerr<<item.first<<": got "<<actual<<", expected "<<item.second<<"\n"; return 1; }
  }
  std::cout<<"PASS cardinal/compound direction display, accepted case/spelling variants and unchanged fallback\n";
}
