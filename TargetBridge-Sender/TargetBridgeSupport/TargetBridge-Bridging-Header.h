//
//  TargetBridge-Bridging-Header.h
//  TargetBridge
//
//  Private API declarations for CGVirtualDisplay and IOAVService.
//  Property names verified against Chromium's virtual_display_mac_util.mm.
//

#ifndef TargetBridge_Bridging_Header_h
#define TargetBridge_Bridging_Header_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// The wire codec, shared verbatim with the receiver so both ends cannot drift
// apart on a format neither of them owns alone.
#import "tb_dpcm.h"
#import "tb_dpcm_gpu.h"

// MARK: - CGVirtualDisplay Private API (macOS 14+)

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic) CGSize   sizeInMillimeters;   // physical size (width, height) in mm
@property (nonatomic) uint32_t maxPixelsWide;       // max pixel width
@property (nonatomic) uint32_t maxPixelsHigh;       // max pixel height
@property (nonatomic) NSPoint  whitePoint;
@property (nonatomic) NSPoint  redPrimary;
@property (nonatomic) NSPoint  greenPrimary;
@property (nonatomic) NSPoint  bluePrimary;
@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) uint32_t vendorID;
@property (nonatomic) uint32_t productID;
@property (nonatomic) uint32_t serialNum;
@property (nonatomic) uint32_t serialNumber;
@property (nonatomic, copy) id terminationHandler;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
                  refreshRate:(double)refreshRate;
/* Found by runtime introspection, not documentation. A virtual display is 8-bpc
 * because it is SDR; declaring a transfer function is what makes macOS treat it
 * as HDR and promote the framebuffer to 16-bpc, which is the only reason our
 * 10-bit capture currently carries 8 bits of real data. BetterDisplay's "Enable
 * HDR support" does exactly this — its help text says "16-bpc ... default is
 * 8-bpc, SDR".
 *
 * The value is an unsigned enum whose meanings are undocumented; TBTransferFn
 * exists so it can be found empirically. */
- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
                  refreshRate:(double)refreshRate
             transferFunction:(unsigned int)transferFunction;
@property (nonatomic) unsigned int transferFunction;
@property (nonatomic, readonly) NSUInteger width;
@property (nonatomic, readonly) NSUInteger height;
@property (nonatomic, readonly) double     refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic) BOOL hiDPI;
@property (nonatomic, copy) NSArray *modes;
/* Found by runtime introspection (scratchpad/vdintrospect.m), not documentation
 * — these exist on the real class and were simply never declared here.
 *
 * `refreshDeadline` is the interesting one. A virtual display has no scanout to
 * force a rhythm, so it composites on demand: leave the screen alone and
 * content production sags to ~5.6 Hz, which is why the first keystroke after a
 * pause waits ~180 ms before anything appears. A deadline is exactly the beat
 * that is missing. Units and semantics are unknown and there is nothing to read
 * — it is set empirically, behind TBRefreshDeadline, and left off by default. */
@property (nonatomic) double refreshDeadline;
@property (nonatomic) BOOL isReference;
@property (nonatomic) uint32_t rotation;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (nonatomic, readonly) CGDirectDisplayID displayID;
@end

// MARK: - CGSDisplayMode (advanced resolution switching)

typedef struct {
    uint32_t modeID;
    uint32_t width;
    uint32_t height;
    uint32_t depth;
    double   refreshRate;
    uint32_t flags;        // bit 0x20000 = HiDPI
} CGSDisplayMode;

typedef int CGSConnectionID_t;
extern CGError CGSConfigureDisplayMode(CGSConnectionID_t connection, CGDirectDisplayID display, uint32_t modeID);
extern CGSConnectionID_t CGSMainConnectionID(void);

// MARK: - IOAVService Private API (Apple Silicon DDC)

typedef void * IOAVServiceRef;
extern IOAVServiceRef IOAVServiceCreate(CFAllocatorRef allocator);
extern IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service);
extern IOReturn IOAVServiceReadI2C(IOAVServiceRef service,
                                   uint32_t chipAddress,
                                   uint32_t offset,
                                   void *outputBuffer,
                                   uint32_t outputBufferSize);
extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef service,
                                    uint32_t chipAddress,
                                    uint32_t dataAddress,
                                    void *inputBuffer,
                                    uint32_t inputBufferSize);

#endif /* TargetBridge_Bridging_Header_h */
