//
//  MTIAsyncImageView.m
//  MetalPetal
//
//  Created by Yu Ao on 2019/6/12.
//
#if __has_include(<UIKit/UIKit.h>) && __is_target_os(iOS)

#import <UIKit/UIKit.h>
#import "MTIImage.h"
#import "MTIContext+Rendering.h"
#import "MTIThreadSafeImageView.h"
#import "MTILock.h"
#import "MTIPrint.h"
#import "MTIError.h"
#import "MTIRenderTask.h"

NSString * const MTIImageViewErrorDomain = @"MTIImageViewErrorDomain";


@protocol MTICAMetalLayer

@property(nullable, retain) id<MTLDevice> device;

@property MTLPixelFormat pixelFormat;

@property CGSize drawableSize;

@property(getter=isOpaque) BOOL opaque;

@property CGFloat contentsScale;

@property (nullable) CGColorSpaceRef colorspace;

- (id<CAMetalDrawable>)nextDrawable;

@end


// For simulator < iOS 13
__attribute__((objc_subclassing_restricted))
@interface MTIStubMetalLayer : CALayer <MTICAMetalLayer>

@property (nullable, retain, atomic) id<MTLDevice> device;

@property (atomic) MTLPixelFormat pixelFormat;

@property (atomic) CGSize drawableSize;

@property (nullable) CGColorSpaceRef colorspace;

@end

@implementation MTIStubMetalLayer

- (id<CAMetalDrawable>)nextDrawable {
    return nil;
}

- (CGColorSpaceRef)colorspace {
    return nil;
}

- (void)setColorspace:(CGColorSpaceRef)colorspace {
    
}

@end


@interface CAMetalLayer (MTICAMetalLayerProtocol) <MTICAMetalLayer>

@end

@implementation CAMetalLayer (MTICAMetalLayerProtocol)

@end


@interface MTIThreadSafeImageView ()

@property (nonatomic, readonly, strong) id<MTICAMetalLayer> renderLayer;

@property (nonatomic) CGFloat screenScale;

@property (nonatomic) id<CAMetalDrawable> currentDrawable;

@property (nonatomic) id<MTILocking> lock;

@property (nonatomic) CGRect backgroundAccessingBounds;

@property (nonatomic) BOOL currentDrawableValid;

@property (nonatomic) CGSize currentDrawableSize;

@property (nonatomic, strong) NSError *contextCreationError;

@end

@implementation MTIThreadSafeImageView
@synthesize context = _context;
@synthesize image = _image;
@synthesize clearColor = _clearColor;
@synthesize resizingMode = _resizingMode;

+ (Class)layerClass {
#if TARGET_OS_SIMULATOR
    if (@available(iOS 13.0, *)) {
        return CAMetalLayer.class;
    } else {
        return MTIStubMetalLayer.class;
    }
#else
    return CAMetalLayer.class;
#endif
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        [self setupImageView];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    if (self = [super initWithCoder:aDecoder]) {
        [self setupImageView];
    }
    return self;
}

- (void)setupImageView {
    _renderLayer = (id)self.layer;
    _resizingMode = MTIDrawableRenderingResizingModeAspect;
    _automaticallyCreatesContext = YES;
    _renderLayer.device = nil;
    _currentDrawableSize = _renderLayer.drawableSize;
    _lock = MTILockCreate();
    self.opaque = YES;
}

- (void)setOpaque:(BOOL)opaque {
    NSAssert(NSThread.isMainThread, @"");
    [_lock lock];
    BOOL oldOpaque = [super isOpaque];
    [super setOpaque:opaque];
    _renderLayer.opaque = opaque;
    if (oldOpaque != opaque) {
        [self renderImage:_image completion:nil];
    }
    [_lock unlock];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [_lock lock];
    if (self.window.screen) {
        _screenScale = MIN(self.window.screen.nativeScale, self.window.screen.scale);
    } else {
        _screenScale = 1.0;
    }
    [_lock unlock];
}

- (void)setContext:(MTIContext *)context {
    [_lock lock];
    _context = context;
    _renderLayer.device = context.device;
    [_lock unlock];
}

- (MTIContext *)context {
    [_lock lock];
    [self setupContextIfNeeded];
    MTIContext *c = _context;
    [_lock unlock];
    return c;
}

- (void)setupContextIfNeeded {
    NSAssert([_lock tryLock] == NO, @"");
    if (!_context && !_contextCreationError && _automaticallyCreatesContext) {
        NSError *error;
        _context = [[MTIContext alloc] initWithDevice:MTLCreateSystemDefaultDevice() error:&error];
        if (error) {
            _contextCreationError = error;
        }
        _renderLayer.device = _context.device;
    }
}

- (void)setColorPixelFormat:(MTLPixelFormat)colorPixelFormat {
    [_lock lock];
    if (_renderLayer.pixelFormat != colorPixelFormat) {
        _renderLayer.pixelFormat = colorPixelFormat;
        [self renderImage:_image completion:nil];
    }
    [_lock unlock];
}

- (MTLPixelFormat)colorPixelFormat {
    [_lock lock];
    MTLPixelFormat format = _renderLayer.pixelFormat;
    [_lock unlock];
    return format;
}

- (void)setColorSpace:(CGColorSpaceRef)colorSpace {
    [_lock lock];
    if (_renderLayer.colorspace != colorSpace) {
        _renderLayer.colorspace = colorSpace;
        [self renderImage:_image completion:nil];
    }
    [_lock unlock];
}

- (CGColorSpaceRef)colorSpace {
    [_lock lock];
    CGColorSpaceRef colorspace = _renderLayer.colorspace;
    [_lock unlock];
    return colorspace;
}

- (void)setClearColor:(MTLClearColor)clearColor {
    [_lock lock];
    if (_clearColor.red != clearColor.red ||
        _clearColor.green != clearColor.green ||
        _clearColor.blue != clearColor.blue ||
        _clearColor.alpha != clearColor.alpha
        ) {
        _clearColor = clearColor;
        [self renderImage:_image completion:nil];
    }
    [_lock unlock];
}

- (MTLClearColor)clearColor {
    [_lock lock];
    MTLClearColor color = _clearColor;
    [_lock unlock];
    return color;
}

- (void)setImage:(MTIImage *)image {
    [self setImage:image renderCompletion:nil];
}

- (void)setImage:(MTIImage *)image renderCompletion:(void (^)(NSError *))renderCompletion {
    BOOL renderImage = NO;
    
    [_lock lock];
    if (_image != image) {
        _image = image;
        renderImage = YES;
        [self renderImage:image completion:renderCompletion];
    }
    [_lock unlock];
    
    if (!renderImage) {
        if (renderCompletion) {
            renderCompletion([NSError errorWithDomain:MTIImageViewErrorDomain code:MTIImageViewErrorSameImage userInfo:nil]);
        }
    }
}

- (MTIImage *)image {
    [_lock lock];
    MTIImage *image = _image;
    [_lock unlock];
    return image;
}

- (void)setResizingMode:(MTIDrawableRenderingResizingMode)resizingMode {
    [_lock lock];
    if (_resizingMode != resizingMode) {
        _resizingMode = resizingMode;
        [self renderImage:_image completion:nil];
    }
    [_lock unlock];
}

- (MTIDrawableRenderingResizingMode)resizingMode {
    [_lock lock];
    MTIDrawableRenderingResizingMode resizingMode = _resizingMode;
    [_lock unlock];
    return resizingMode;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    
    [_lock lock];
    if (!CGRectEqualToRect(_backgroundAccessingBounds, self.bounds)) {
        _backgroundAccessingBounds = self.bounds;
        [self renderImage:_image completion:nil];
    }
    [_lock unlock];
}

// locking access

- (void)renderImage:(MTIImage *)image completion:(void (^)(NSError *))completion {
    NSAssert([_lock tryLock] == NO, @"");
    
    [self setupContextIfNeeded];
    
    MTIContext *context = self -> _context;
    if (!context) {
        if (completion) {
            completion(_contextCreationError ?: [NSError errorWithDomain:MTIImageViewErrorDomain code:MTIImageViewErrorContextNotFound userInfo:nil]);
        }
        return;
    }
    
    [self updateContentScaleFactor];
    
    MTIImage *imageToRender = image;
    MTIDrawableRenderingResizingMode resizingMode = self -> _resizingMode;
    //and acquire _clearColor
    
    [self invalidateCurrentDrawable];
    
    MTIDrawableRenderingRequest *request = [[MTIDrawableRenderingRequest alloc] initWithDrawableProvider:self resizingMode:resizingMode];

    if (imageToRender) {
        NSError *error;
        [context startTaskToRenderImage:image
                  toDrawableWithRequest:request
                                  error:&error
                             completion:^(MTIRenderTask * _Nonnull task) {
                                 if (completion) {
                                     completion(task.error);
                                 }
                             }];
        if (error) {
            MTIPrint(@"%@: Failed to render image %@ - %@",self,imageToRender,error);
            if (completion) {
                completion(error);
            }
        }
    } else {
        //Clear current drawable.
        MTLRenderPassDescriptor *renderPassDescriptor = [self renderPassDescriptorForRequest:request];
        id<MTLDrawable> drawable = [self drawableForRequest:request];
        if (renderPassDescriptor && drawable) {
            id<MTLCommandBuffer> commandBuffer = [context.commandQueue commandBuffer];
            id<MTLRenderCommandEncoder> commandEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
            [commandEncoder endEncoding];
            [commandBuffer presentDrawable:drawable];
            [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> cb) {
                if (completion) {
                    completion(cb.error);
                }
            }];
            [commandBuffer commit];
        } else {
            if (completion) {
                completion(MTIErrorCreate(MTIErrorEmptyDrawable, nil));
            }
        }
    }
}

- (void)updateContentScaleFactor {
    NSAssert([_lock tryLock] == NO, @"");

    __auto_type renderLayer = _renderLayer;
    if (_backgroundAccessingBounds.size.width > 0 && _backgroundAccessingBounds.size.height > 0 && _image && _image.size.width > 0 && _image.size.height > 0) {
        CGSize imageSize = _image.size;
        CGFloat widthScale = imageSize.width/_backgroundAccessingBounds.size.width;
        CGFloat heightScale = imageSize.height/_backgroundAccessingBounds.size.height;
        CGFloat nativeScale = _screenScale;
        CGFloat scale = MAX(MIN(MAX(widthScale,heightScale),nativeScale), 1.0);
        CGSize drawableSize = CGSizeMake(_backgroundAccessingBounds.size.width * scale, _backgroundAccessingBounds.size.height * scale);
        if (ABS(renderLayer.contentsScale - scale) > 0.00001 || !CGSizeEqualToSize(drawableSize, _currentDrawableSize)) {
            renderLayer.contentsScale = scale;
            renderLayer.drawableSize = drawableSize;
            _currentDrawableSize = drawableSize;
        }
    }
}

- (void)invalidateCurrentDrawable {
    NSAssert([_lock tryLock] == NO, @"");
    _currentDrawableValid = NO;
}

- (void)requestNextDrawableIfNeeded {
    NSAssert([_lock tryLock] == NO, @"");
    if (!_currentDrawableValid) {
        _currentDrawable = _renderLayer.nextDrawable;
        _currentDrawableValid = YES;
    }
}

- (id<MTLDrawable>)drawableForRequest:(MTIDrawableRenderingRequest *)request {
    NSAssert([_lock tryLock] == NO, @"");
    [self requestNextDrawableIfNeeded];
    return _currentDrawable;
}

- (MTLRenderPassDescriptor *)renderPassDescriptorForRequest:(MTIDrawableRenderingRequest *)request {
    NSAssert([_lock tryLock] == NO, @"");
    [self requestNextDrawableIfNeeded];
    MTLRenderPassDescriptor *descriptor = [[MTLRenderPassDescriptor alloc] init];
    descriptor.colorAttachments[0].texture = _currentDrawable.texture;
    descriptor.colorAttachments[0].clearColor = _clearColor;
    descriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    return descriptor;
}

@end

#endif
