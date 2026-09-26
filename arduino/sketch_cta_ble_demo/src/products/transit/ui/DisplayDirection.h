#pragma once
#include <cctype>
#include <string>

namespace TransitDisplay {
inline std::string displayDirection(const std::string& value) {
  std::string lower=value;
  for(char& c:lower) c=char(std::tolower(static_cast<unsigned char>(c)));
  // Match the phone's N. East / N. West / S. East / S. West convention
  // before the cardinal substring checks. Normalize only the compound prefix.
  std::string compact;
  for(char c:lower) if(c!='.' && c!='-' && !std::isspace(static_cast<unsigned char>(c))) compact+=c;
  if(compact.rfind("northeast",0)==0 || compact.rfind("neast",0)==0) return "N. East";
  if(compact.rfind("northwest",0)==0 || compact.rfind("nwest",0)==0) return "N. West";
  if(compact.rfind("southeast",0)==0 || compact.rfind("seast",0)==0) return "S. East";
  if(compact.rfind("southwest",0)==0 || compact.rfind("swest",0)==0) return "S. West";
  if(lower.find("east")!=std::string::npos) return "East";
  if(lower.find("west")!=std::string::npos) return "West";
  if(lower.find("south")!=std::string::npos) return "South";
  if(lower.find("north")!=std::string::npos) return "North";
  constexpr const char* prefix="Platform ";
  return value.rfind(prefix,0)==0 ? value.substr(9) : value;
}
}
