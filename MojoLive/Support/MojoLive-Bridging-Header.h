//
//  MojoLive-Bridging-Header.h
//  Expone la API C de libsrt (Haivision SRT) a Swift.
//
//  Los headers se instalan dentro de Vendor/libsrt.xcframework/<slice>/Headers/srt/
//  mediante Scripts/build-libsrt.sh. Xcode los agrega automáticamente al
//  header search path al linkear el XCFramework.
//

#ifndef MojoLive_Bridging_Header_h
#define MojoLive_Bridging_Header_h

#include <srt/srt.h>

#endif
