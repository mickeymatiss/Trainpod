#pragma once
#include <stdint.h>
#include <math.h>
// Device correction map: option 2, fitted visually on this Waveshare LCD.
// Snapshot of 53 visual matches at brightness 80. RGB888 in, RGB888 out.
// RGB inverse-distance^4 weighting of correction deltas; exact anchors preserved.
namespace compact_colorscape {
struct Anchor { uint32_t target, output; };
static const Anchor anchors[] = {
    {0x000000, 0x000000},
    {0x808080, 0x7A745B},
    {0xFFECEA, 0xFCF1E5},
    {0xF70000, 0xF10000},
    {0xFFB485, 0xFDD9BD},
    {0x62AE78, 0x7EC082},
    {0x4DAFA9, 0x1CB8A6},
    {0x527AC7, 0x8BA1C9},
    {0x19005D, 0x12006E},
    {0xF2B6C6, 0xF5CDCE},
    {0xDCC9A3, 0xE6DDB3},
    {0x3D4114, 0x615F00},
    {0x34E513, 0x54D600},
    {0x675B0B, 0x9D7D00},
    {0xD49F2B, 0xE6C954},
    {0x4D219D, 0x703AA3},
    {0x66E8CD, 0x46DDBC},
    {0xF241FA, 0xF88BF5},
    {0xCA78F8, 0xE08CE7},
    {0xBCCDE6, 0xBEC3B1},
    {0xBB60F8, 0xD173D1},
    {0xD09FE2, 0xD3B0C2},
    {0x491C29, 0x721B1D},
    {0x4E95CB, 0x5AA9B5},
    {0xF08349, 0xFCC075},
    {0x652BFF, 0x8672D8},
    {0x3BD4FD, 0x13D3D3},
    {0x0CF69D, 0x4BD998},
    {0xE9F583, 0xEAE9A7},
    {0x6AFA7A, 0x8FDD8D},
    {0xA1B5BE, 0xABB4A5},
    {0x15527A, 0x117CAC},
    {0xE6E7F8, 0xCBCFBD},
    {0xE842BC, 0xEB52B6},
    {0x0000DF, 0x003EC7},
    {0x802808, 0xC72800},
    {0x001800, 0x0E1000},
    {0x008F00, 0x00A700},
    {0x9F0080, 0xCD0084},
    {0xB76000, 0xCC6200},
    {0x9F00D7, 0xC1289B},
    {0x100018, 0x010002},
    {0x007868, 0x30AD82},
    {0x785070, 0xA05C69},
    {0xFF78A7, 0xE47E84},
    {0x680060, 0x9E004B},
    {0xBF4870, 0xEB7C8E},
    {0x878718, 0xA09600},
    {0x7868FF, 0xA9A2D0},
    {0xA7B780, 0xCBC379},
    {0xC7CF00, 0xD1D100},
    {0x003048, 0x003A4C},
    {0xFFAFFF, 0xF3CEE6},
};
inline uint32_t correct(uint32_t rgb) {
    if(rgb>0xFFFFFF) return rgb;
    float x[3]={float((rgb>>16)&255),float((rgb>>8)&255),float(rgb&255)};
    float delta[3]={},total=0;
    for(const auto& a:anchors) {
        if(rgb==a.target) return a.output;
        float t[3]={float((a.target>>16)&255),float((a.target>>8)&255),float(a.target&255)};
        float o[3]={float((a.output>>16)&255),float((a.output>>8)&255),float(a.output&255)};
        float d=0;for(int c=0;c<3;++c) d+=(x[c]-t[c])*(x[c]-t[c]);
        float w=1/(d*d);total+=w;for(int c=0;c<3;++c) delta[c]+=w*(o[c]-t[c]);
    }
    uint32_t result=0;
    for(int c=0;c<3;++c) result=(result<<8)|uint32_t(lroundf(fminf(255,fmaxf(0,x[c]+delta[c]/total))));
    return result;
}
}
