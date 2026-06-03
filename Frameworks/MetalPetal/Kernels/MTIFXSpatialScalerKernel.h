//
//  MTIFXSpatialScalerKernel.h
//  MetalPetal
//
//  Wraps MetalFX (`MTLFXSpatialScaler`) as an `MTIImage`-producing kernel, mirroring
//  `MTIMPSKernel`. The kernel encodes a spatial upscale into the render graph's command
//  buffer, so it composes with the rest of MetalPetal's lazy rendering.
//
//  Requires macOS 13 / iOS 16 and a MetalFX-capable device. Callers must check
//  `+isSupportedByDevice:` before use and provide a fallback (e.g. Lanczos) otherwise.
//

#import <Metal/Metal.h>

#if __has_include(<MetalPetal/MetalPetal.h>)
#import <MetalPetal/MTITextureDimensions.h>
#else
#import "MTITextureDimensions.h"
#endif

NS_ASSUME_NONNULL_BEGIN

@class MTIImage;

API_AVAILABLE(macos(13.0), ios(16.0), tvos(16.0), visionos(1.0))
__attribute__((objc_subclassing_restricted))
@interface MTIFXSpatialScalerKernel : NSObject

- (instancetype)init NS_DESIGNATED_INITIALIZER;

/// Whether MetalFX spatial scaling is supported on the given device.
+ (BOOL)isSupportedByDevice:(id<MTLDevice>)device;

/// Produce an image that upscales `image` to `outputTextureDimensions` using a MetalFX
/// spatial scaler. The scaler is created lazily and cached per (device, sizes, pixel format).
- (MTIImage *)applyToInputImage:(MTIImage *)image
        outputTextureDimensions:(MTITextureDimensions)outputTextureDimensions NS_SWIFT_NAME(apply(toInputImage:outputTextureDimensions:));

@end

NS_ASSUME_NONNULL_END
