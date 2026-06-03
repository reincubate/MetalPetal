//
//  MTIFXSpatialScalerKernel.m
//  MetalPetal
//

#import "MTIFXSpatialScalerKernel.h"
#import "MTIImage.h"
#import "MTIImage+Promise.h"
#import "MTIContext.h"
#import "MTIContext+Internal.h"
#import "MTITextureDescriptor.h"
#import "MTIImageRenderingContext.h"
#import "MTIImagePromise.h"
#import "MTIImagePromiseDebug.h"

#import <MetalFX/MetalFX.h>

static NSString * const MTIFXSpatialScalerErrorDomain = @"com.metalpetal.MTIFXSpatialScalerKernel";

API_AVAILABLE(macos(13.0), ios(16.0), tvos(16.0), visionos(1.0))
@interface MTIFXSpatialScalerKernel ()

// Cache of spatial scalers keyed by "<device>-<inW>-<inH>-<outW>-<outH>-<pixelFormat>".
// Creating a scaler is non-trivial and the render resolution is stable frame-to-frame.
@property (nonatomic, strong, readonly) NSMutableDictionary<NSString *, id<MTLFXSpatialScaler>> *scalerCache;

- (nullable id<MTLFXSpatialScaler>)scalerForDevice:(id<MTLDevice>)device
                                        inputWidth:(NSUInteger)inputWidth
                                       inputHeight:(NSUInteger)inputHeight
                                       outputWidth:(NSUInteger)outputWidth
                                      outputHeight:(NSUInteger)outputHeight
                                       pixelFormat:(MTLPixelFormat)pixelFormat
                                             error:(NSError * __autoreleasing *)error;

@end

#pragma mark - Promise

API_AVAILABLE(macos(13.0), ios(16.0), tvos(16.0), visionos(1.0))
__attribute__((objc_subclassing_restricted))
@interface MTIFXSpatialScalerProcessingRecipe : NSObject <MTIImagePromise>

@property (nonatomic, strong, readonly) MTIFXSpatialScalerKernel *kernel;
@property (nonatomic, copy, readonly) NSArray<MTIImage *> *inputImages;

@end

@implementation MTIFXSpatialScalerProcessingRecipe

@synthesize dimensions = _dimensions;
@synthesize alphaType = _alphaType;

- (instancetype)initWithKernel:(MTIFXSpatialScalerKernel *)kernel
                    inputImage:(MTIImage *)inputImage
       outputTextureDimensions:(MTITextureDimensions)outputTextureDimensions {
    if (self = [super init]) {
        _kernel = kernel;
        _inputImages = @[inputImage];
        _dimensions = outputTextureDimensions;
        _alphaType = inputImage.alphaType;
    }
    return self;
}

- (NSArray<MTIImage *> *)dependencies {
    return self.inputImages;
}

- (MTIImagePromiseRenderTarget *)resolveWithContext:(MTIImageRenderingContext *)renderingContext error:(NSError * __autoreleasing *)inOutError {
    id<MTLTexture> inputTexture = [renderingContext resolvedTextureForImage:self.inputImages[0]];
    MTLPixelFormat pixelFormat = inputTexture.pixelFormat;

    NSError *error = nil;
    id<MTLFXSpatialScaler> scaler = [self.kernel scalerForDevice:renderingContext.context.device
                                                      inputWidth:inputTexture.width
                                                     inputHeight:inputTexture.height
                                                     outputWidth:self.dimensions.width
                                                    outputHeight:self.dimensions.height
                                                     pixelFormat:pixelFormat
                                                           error:&error];
    if (!scaler) {
        if (inOutError) { *inOutError = error; }
        return nil;
    }

    // Allocate the upscaled output. MetalFX requires the destination to satisfy
    // `outputTextureUsage`; downstream MetalPetal stages additionally sample it, so we add
    // shaderRead.
    MTITextureDescriptor *outputDescriptor = [MTITextureDescriptor texture2DDescriptorWithPixelFormat:pixelFormat
                                                                                                width:self.dimensions.width
                                                                                               height:self.dimensions.height
                                                                                            mipmapped:NO
                                                                                                usage:(scaler.outputTextureUsage | MTLTextureUsageShaderRead)
                                                                                      resourceOptions:MTLResourceStorageModePrivate];
    MTIImagePromiseRenderTarget *renderTarget = [renderingContext.context newRenderTargetWithReusableTextureDescriptor:outputDescriptor error:&error];
    if (error) {
        if (inOutError) { *inOutError = error; }
        return nil;
    }

    // MetalFX requires the input color texture to satisfy `colorTextureUsage`. MetalPetal's
    // resolved textures are sampled downstream so they normally include shaderRead; if a
    // particular input does not, blit it into a conforming texture first.
    id<MTLTexture> colorTexture = inputTexture;
    if ((inputTexture.usage & scaler.colorTextureUsage) != scaler.colorTextureUsage) {
        MTLTextureDescriptor *conformingDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pixelFormat
                                                                                                        width:inputTexture.width
                                                                                                       height:inputTexture.height
                                                                                                    mipmapped:NO];
        conformingDescriptor.usage = inputTexture.usage | scaler.colorTextureUsage;
        conformingDescriptor.storageMode = MTLStorageModePrivate;
        id<MTLTexture> conformingTexture = [renderingContext.context.device newTextureWithDescriptor:conformingDescriptor];
        id<MTLBlitCommandEncoder> blit = [renderingContext.commandBuffer blitCommandEncoder];
        [blit copyFromTexture:inputTexture
                  sourceSlice:0
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(inputTexture.width, inputTexture.height, 1)
                    toTexture:conformingTexture
             destinationSlice:0
             destinationLevel:0
            destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding];
        colorTexture = conformingTexture;
    }

    // A scaler is cached and may be shared by concurrent contexts at the same resolution. Its
    // texture properties are per-encode state, so serialise configuring + encoding it.
    @synchronized (scaler) {
        scaler.colorTexture = colorTexture;
        scaler.outputTexture = renderTarget.texture;
        scaler.inputContentWidth = inputTexture.width;
        scaler.inputContentHeight = inputTexture.height;
        [scaler encodeToCommandBuffer:renderingContext.commandBuffer];
    }

    return renderTarget;
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

- (instancetype)promiseByUpdatingDependencies:(NSArray<MTIImage *> *)dependencies {
    NSParameterAssert(dependencies.count == 1);
    return [[MTIFXSpatialScalerProcessingRecipe alloc] initWithKernel:self.kernel
                                                          inputImage:dependencies.firstObject
                                             outputTextureDimensions:self.dimensions];
}

- (MTIImagePromiseDebugInfo *)debugInfo {
    return [[MTIImagePromiseDebugInfo alloc] initWithPromise:self
                                                        type:MTIImagePromiseTypeProcessor
                                                     content:@{@"outputWidth": @(self.dimensions.width),
                                                               @"outputHeight": @(self.dimensions.height)}];
}

@end

#pragma mark - Kernel

@implementation MTIFXSpatialScalerKernel

- (instancetype)init {
    if (self = [super init]) {
        _scalerCache = [NSMutableDictionary dictionary];
    }
    return self;
}

+ (BOOL)isSupportedByDevice:(id<MTLDevice>)device {
    return [MTLFXSpatialScalerDescriptor supportsDevice:device];
}

- (nullable id<MTLFXSpatialScaler>)scalerForDevice:(id<MTLDevice>)device
                                        inputWidth:(NSUInteger)inputWidth
                                       inputHeight:(NSUInteger)inputHeight
                                       outputWidth:(NSUInteger)outputWidth
                                      outputHeight:(NSUInteger)outputHeight
                                       pixelFormat:(MTLPixelFormat)pixelFormat
                                             error:(NSError * __autoreleasing *)error {
    NSString *key = [NSString stringWithFormat:@"%p-%lu-%lu-%lu-%lu-%lu",
                     device,
                     (unsigned long)inputWidth, (unsigned long)inputHeight,
                     (unsigned long)outputWidth, (unsigned long)outputHeight,
                     (unsigned long)pixelFormat];
    @synchronized (self) {
        id<MTLFXSpatialScaler> cached = self.scalerCache[key];
        if (cached) {
            return cached;
        }

        MTLFXSpatialScalerDescriptor *descriptor = [[MTLFXSpatialScalerDescriptor alloc] init];
        descriptor.inputWidth = inputWidth;
        descriptor.inputHeight = inputHeight;
        descriptor.outputWidth = outputWidth;
        descriptor.outputHeight = outputHeight;
        descriptor.colorTextureFormat = pixelFormat;
        descriptor.outputTextureFormat = pixelFormat;
        // Camera frames are gamma-encoded (non-linear) in MetalPetal's working space.
        descriptor.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;

        id<MTLFXSpatialScaler> scaler = [descriptor newSpatialScalerWithDevice:device];
        if (!scaler) {
            if (error) {
                *error = [NSError errorWithDomain:MTIFXSpatialScalerErrorDomain
                                             code:1
                                         userInfo:@{NSLocalizedDescriptionKey: @"Failed to create MTLFXSpatialScaler for the requested configuration."}];
            }
            return nil;
        }
        self.scalerCache[key] = scaler;
        return scaler;
    }
}

- (MTIImage *)applyToInputImage:(MTIImage *)image outputTextureDimensions:(MTITextureDimensions)outputTextureDimensions {
    MTIFXSpatialScalerProcessingRecipe *recipe = [[MTIFXSpatialScalerProcessingRecipe alloc] initWithKernel:self
                                                                                                inputImage:image
                                                                                   outputTextureDimensions:outputTextureDimensions];
    return [[MTIImage alloc] initWithPromise:recipe];
}

@end
