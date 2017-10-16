//
//  MTIRenderPipelineKernel.m
//  Pods
//
//  Created by YuAo on 02/07/2017.
//
//

#import "MTIRenderPipelineKernel.h"
#import "MTIContext.h"
#import "MTIFunctionDescriptor.h"
#import "MTIImage.h"
#import "MTIImagePromise.h"
#import "MTIVertex.h"
#import "MTIImageRenderingContext.h"
#import "MTITextureDescriptor.h"
#import "MTIRenderPipeline.h"
#import "MTIImage+Promise.h"
#import "MTIDefer.h"
#import "MTIWeakToStrongObjectsMapTable.h"
#import "MTILock.h"

@interface MTIRenderPipelineKernelConfiguration: NSObject <MTIKernelConfiguration>

@property (nonatomic,copy,readonly) NSArray<NSNumber *> *colorAttachmentPixelFormats;

@end

@implementation MTIRenderPipelineKernelConfiguration
@synthesize identifier = _identifier;

- (instancetype)initWithColorAttachmentPixelFormats:(NSArray<NSNumber *> *)colorAttachmentPixelFormats {
    if (self = [super init]) {
        _colorAttachmentPixelFormats = [colorAttachmentPixelFormats copy];
        NSMutableString *identifier = [NSMutableString string];
        for (NSNumber *value in colorAttachmentPixelFormats) {
            // Using "/" to make the result fits in a tagged pointer.
            // table = "eilotrm.apdnsIc ufkMShjTRxgC4013bDNvwyUL2O856P-B79AFKEWV_zGJ/HYX";
            // ref: https://www.mikeash.com/pyblog/friday-qa-2015-07-31-tagged-pointer-strings.html
            [identifier appendFormat:@"/%@/",value];
        }
        _identifier = [identifier copy];
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

+ (instancetype)configurationWithColorAttachmentPixelFormats:(NSArray<NSNumber *> *)colorAttachmentPixelFormats {
    return [[MTIRenderPipelineKernelConfiguration alloc] initWithColorAttachmentPixelFormats:colorAttachmentPixelFormats];
}

@end

@interface MTIImageRenderingRecipe : NSObject

@property (nonatomic,copy,readonly) NSArray<MTIImage *> *inputImages;

@property (nonatomic,strong,readonly) MTIRenderPipelineKernel *kernel;

@property (nonatomic,copy,readonly) NSDictionary<NSString *, id> *functionParameters;

@property (nonatomic,copy,readonly) NSArray<MTIRenderPipelineOutputDescriptor *> *outputDescriptors;

@property (nonatomic, strong, readonly) MTIWeakToStrongObjectsMapTable *resolutionCache;
@property (nonatomic, strong, readonly) id<NSLocking> resolutionCacheLock;

@end

@implementation MTIImageRenderingRecipe

- (MTIVertices *)verticesForRect:(CGRect)rect {
    CGFloat l = CGRectGetMinX(rect);
    CGFloat r = CGRectGetMaxX(rect);
    CGFloat t = CGRectGetMinY(rect);
    CGFloat b = CGRectGetMaxY(rect);
    
    return [[MTIVertices alloc] initWithVertices:(MTIVertex []){
        { .position = {l, t, 0, 1} , .textureCoordinate = { 0, 1 } },
        { .position = {r, t, 0, 1} , .textureCoordinate = { 1, 1 } },
        { .position = {l, b, 0, 1} , .textureCoordinate = { 0, 0 } },
        { .position = {r, b, 0, 1} , .textureCoordinate = { 1, 0 } }
    } count:4];
}

- (NSArray<MTIImagePromiseRenderTarget *> *)resolveWithContext:(MTIImageRenderingContext *)renderingContext resolver:(id<MTIImagePromise>)promise error:(NSError * _Nullable __autoreleasing *)inOutError {
    NSError *error = nil;
    NSMutableArray<id<MTIImagePromiseResolution>> *inputResolutions = [NSMutableArray array];
    for (MTIImage *image in self.inputImages) {
        id<MTIImagePromiseResolution> resolution = [renderingContext resolutionForImage:image error:&error];
        if (error) {
            if (inOutError) {
                *inOutError = error;
            }
            return nil;
        }
        NSAssert(resolution != nil, @"");
        [inputResolutions addObject:resolution];
    }
    
    @MTI_DEFER {
        for (id<MTIImagePromiseResolution> resolution in inputResolutions) {
            [resolution markAsConsumedBy:promise];
        }
    };
    
    NSMutableArray<NSNumber *> *pixelFormats = [NSMutableArray array];
    for (MTIRenderPipelineOutputDescriptor *outputDescriptor in self.outputDescriptors) {
        MTLPixelFormat pixelFormat = (outputDescriptor.pixelFormat == MTIPixelFormatUnspecified) ? renderingContext.context.workingPixelFormat : outputDescriptor.pixelFormat;
        [pixelFormats addObject:@(pixelFormat)];
    }
    
    MTIRenderPipeline *renderPipeline = [renderingContext.context kernelStateForKernel:self.kernel configuration:[MTIRenderPipelineKernelConfiguration configurationWithColorAttachmentPixelFormats:pixelFormats] error:&error];
    
    if (error) {
        if (inOutError) {
            *inOutError = error;
        }
        return nil;
    }
    
    NSMutableArray<MTIImagePromiseRenderTarget *> *renderTargets = [NSMutableArray array];
    
    MTLRenderPassDescriptor *renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];

    for (NSUInteger index = 0; index < self.kernel.colorAttachmentCount; index += 1) {
        MTLPixelFormat pixelFormat = [pixelFormats[index] MTLPixelFormatValue];
        
        MTIRenderPipelineOutputDescriptor *outputDescriptor = self.outputDescriptors[index];
        MTLTextureDescriptor *textureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pixelFormat width:outputDescriptor.dimensions.width height:outputDescriptor.dimensions.height mipmapped:NO];
        textureDescriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        
        MTIImagePromiseRenderTarget *renderTarget = [renderingContext.context newRenderTargetWithResuableTextureDescriptor:[textureDescriptor newMTITextureDescriptor]];
        
        renderPassDescriptor.colorAttachments[index].texture = renderTarget.texture;
        renderPassDescriptor.colorAttachments[index].clearColor = MTLClearColorMake(0, 0, 0, 0);
        renderPassDescriptor.colorAttachments[index].loadAction = MTLLoadActionDontCare;
        renderPassDescriptor.colorAttachments[index].storeAction = MTLStoreActionStore;
        
        [renderTargets addObject:renderTarget];
    }
    
    MTIVertices *vertices = [self verticesForRect:CGRectMake(-1, -1, 2, 2)];
    
    __auto_type commandEncoder = [renderingContext.commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
    [commandEncoder setRenderPipelineState:renderPipeline.state];
    
    if (vertices.count * sizeof(MTIVertex) < 4096) {
        //The setVertexBytes:length:atIndex: method is the best option for binding a very small amount (less than 4 KB) of dynamic buffer data to a vertex function. This method avoids the overhead of creating an intermediary MTLBuffer object. Instead, Metal manages a transient buffer for you.
        [commandEncoder setVertexBytes:vertices.buffer length:vertices.count * sizeof(MTIVertex) atIndex:0];
    } else {
        id<MTLBuffer> verticesBuffer = [renderingContext.context.device newBufferWithBytes:vertices.buffer length:vertices.count * sizeof(MTIVertex) options:0];
        [commandEncoder setVertexBuffer:verticesBuffer offset:0 atIndex:0];
    }
    
    for (NSUInteger index = 0; index < inputResolutions.count; index += 1) {
        [commandEncoder setFragmentTexture:inputResolutions[index].texture atIndex:index];
        id<MTLSamplerState> samplerState = [renderingContext.context samplerStateWithDescriptor:self.inputImages[index].samplerDescriptor];
        [commandEncoder setFragmentSamplerState:samplerState atIndex:index];
    }
    
    //encode parameters
    if (self.functionParameters.count > 0) {
        [MTIArgumentsEncoder encodeArguments:renderPipeline.reflection.vertexArguments values:self.functionParameters functionType:MTLFunctionTypeVertex encoder:commandEncoder error:&error];
        if (error) {
            [commandEncoder endEncoding];
            if (inOutError) {
                *inOutError = error;
            }
            return nil;
        }
        
        [MTIArgumentsEncoder encodeArguments:renderPipeline.reflection.fragmentArguments values:self.functionParameters functionType:MTLFunctionTypeFragment encoder:commandEncoder error:&error];
        if (error) {
            [commandEncoder endEncoding];
            if (inOutError) {
                *inOutError = error;
            }
            return nil;
        }
    }
    
    [commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:vertices.count];
    [commandEncoder endEncoding];
    
    return renderTargets;
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

- (instancetype)initWithKernel:(MTIRenderPipelineKernel *)kernel
                   inputImages:(NSArray<MTIImage *> *)inputImages
            functionParameters:(NSDictionary<NSString *,id> *)functionParameters
             outputDescriptors:(NSArray<MTIRenderPipelineOutputDescriptor *> *)outputDescriptors {
    if (self = [super init]) {
        _inputImages = inputImages;
        _kernel = kernel;
        _functionParameters = functionParameters;
        _outputDescriptors = outputDescriptors;
        _resolutionCache = [[MTIWeakToStrongObjectsMapTable alloc] init];
        _resolutionCacheLock = MTILockCreate();
    }
    return self;
}

@end


@interface MTIImageRenderingRecipeView: NSObject <MTIImagePromise>

@property (nonatomic, strong, readonly) MTIImageRenderingRecipe *recipe;

@property (nonatomic, readonly) NSUInteger outputIndex;

@end

@implementation MTIImageRenderingRecipeView

- (NSArray<MTIImage *> *)dependencies {
    return self.recipe.inputImages;
}

- (instancetype)initWithImageRenderingRecipe:(MTIImageRenderingRecipe *)recipe outputIndex:(NSUInteger)index {
    if (self = [super init]) {
        _recipe = recipe;
        _outputIndex = index;
    }
    return self;
}

- (MTITextureDimensions)dimensions {
    return self.recipe.outputDescriptors[self.outputIndex].dimensions;
}

- (MTIImagePromiseRenderTarget *)resolveWithContext:(MTIImageRenderingContext *)renderingContext error:(NSError * _Nullable __autoreleasing *)error {
    [self.recipe.resolutionCacheLock lock];
    @MTI_DEFER {
        [self.recipe.resolutionCacheLock unlock];
    };
    NSArray<MTIImagePromiseRenderTarget *> *renderTargets = [self.recipe.resolutionCache objectForKey:renderingContext];
    if (renderTargets) {
        MTIImagePromiseRenderTarget *renderTarget = renderTargets[self.outputIndex];
        if (renderTarget.texture) {
            return renderTarget;
        }
    }
    renderTargets = [self.recipe resolveWithContext:renderingContext resolver:self error:error];
    if (renderTargets) {
        [self.recipe.resolutionCache setObject:renderTargets forKey:renderingContext];
        return renderTargets[self.outputIndex];
    } else {
        return nil;
    }
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

@end


@interface MTIImageRenderingRecipeSingleOutputView: NSObject <MTIImagePromise>

@property (nonatomic, strong, readonly) MTIImageRenderingRecipe *recipe;

@end

@implementation MTIImageRenderingRecipeSingleOutputView

- (NSArray<MTIImage *> *)dependencies {
    return self.recipe.inputImages;
}

- (instancetype)initWithImageRenderingRecipe:(MTIImageRenderingRecipe *)recipe {
    if (self = [super init]) {
        _recipe = recipe;
    }
    return self;
}

- (MTITextureDimensions)dimensions {
    return self.recipe.outputDescriptors[0].dimensions;
}

- (MTIImagePromiseRenderTarget *)resolveWithContext:(MTIImageRenderingContext *)renderingContext error:(NSError * _Nullable __autoreleasing *)error {
    return [self.recipe resolveWithContext:renderingContext resolver:self error:error].firstObject;
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

@end


@implementation MTIRenderPipelineOutputDescriptor

- (instancetype)initWithDimensions:(MTITextureDimensions)dimensions pixelFormat:(MTLPixelFormat)pixelFormat {
    if (self = [super init]) {
        _dimensions = dimensions;
        _pixelFormat = pixelFormat;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

@end


@interface MTIRenderPipelineKernel ()

@property (nonatomic,copy,readonly) MTIFunctionDescriptor *vertexFunctionDescriptor;
@property (nonatomic,copy,readonly) MTIFunctionDescriptor *fragmentFunctionDescriptor;
@property (nonatomic,copy,readonly) MTLVertexDescriptor *vertexDescriptor;

@end

@implementation MTIRenderPipelineKernel

- (instancetype)initWithVertexFunctionDescriptor:(MTIFunctionDescriptor *)vertexFunctionDescriptor fragmentFunctionDescriptor:(MTIFunctionDescriptor *)fragmentFunctionDescriptor {
    return [self initWithVertexFunctionDescriptor:vertexFunctionDescriptor
                       fragmentFunctionDescriptor:fragmentFunctionDescriptor
                                 vertexDescriptor:nil
                             colorAttachmentCount:1];
}

- (instancetype)initWithVertexFunctionDescriptor:(MTIFunctionDescriptor *)vertexFunctionDescriptor fragmentFunctionDescriptor:(MTIFunctionDescriptor *)fragmentFunctionDescriptor vertexDescriptor:(MTLVertexDescriptor *)vertexDescriptor colorAttachmentCount:(NSUInteger)colorAttachmentCount {
    if (self = [super init]) {
        _vertexFunctionDescriptor = [vertexFunctionDescriptor copy];
        _fragmentFunctionDescriptor = [fragmentFunctionDescriptor copy];
        _vertexDescriptor = [vertexDescriptor copy];
        _colorAttachmentCount = colorAttachmentCount;
    }
    return self;
}

- (id)newKernelStateWithContext:(MTIContext *)context configuration:(MTIRenderPipelineKernelConfiguration *)configuration error:(NSError * _Nullable __autoreleasing *)inOutError {
    NSParameterAssert(configuration.colorAttachmentPixelFormats.count == self.colorAttachmentCount);
    
    MTLRenderPipelineDescriptor *renderPipelineDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    renderPipelineDescriptor.vertexDescriptor = self.vertexDescriptor;
    
    NSError *error;
    id<MTLFunction> vertextFunction = [context functionWithDescriptor:self.vertexFunctionDescriptor error:&error];
    if (error) {
        if (inOutError) {
            *inOutError = error;
        }
        return nil;
    }
    
    id<MTLFunction> fragmentFunction = [context functionWithDescriptor:self.fragmentFunctionDescriptor error:&error];
    if (error) {
        if (inOutError) {
            *inOutError = error;
        }
        return nil;
    }
    
    renderPipelineDescriptor.vertexFunction = vertextFunction;
    renderPipelineDescriptor.fragmentFunction = fragmentFunction;
    
    for (NSUInteger index = 0; index < self.colorAttachmentCount; index += 1) {
        MTLRenderPipelineColorAttachmentDescriptor *colorAttachmentDescriptor = [[MTLRenderPipelineColorAttachmentDescriptor alloc] init];
        colorAttachmentDescriptor.pixelFormat = [configuration.colorAttachmentPixelFormats[index] MTLPixelFormatValue];
        colorAttachmentDescriptor.blendingEnabled = NO;
        renderPipelineDescriptor.colorAttachments[index] = colorAttachmentDescriptor;
    }
    renderPipelineDescriptor.depthAttachmentPixelFormat = MTLPixelFormatInvalid;
    renderPipelineDescriptor.stencilAttachmentPixelFormat = MTLPixelFormatInvalid;
    
    return [context renderPipelineWithDescriptor:renderPipelineDescriptor error:inOutError];
}

- (MTIImage *)applyToInputImages:(NSArray<MTIImage *> *)images parameters:(NSDictionary<NSString *,id> *)parameters outputTextureDimensions:(MTITextureDimensions)outputTextureDimensions outputPixelFormat:(MTLPixelFormat)outputPixelFormat {
    MTIRenderPipelineOutputDescriptor *outputDescriptor = [[MTIRenderPipelineOutputDescriptor alloc] initWithDimensions:outputTextureDimensions pixelFormat:outputPixelFormat];
    return [self applyToInputImages:images parameters:parameters outputDescriptors:@[outputDescriptor]].firstObject;
}

- (NSArray<MTIImage *> *)applyToInputImages:(NSArray<MTIImage *> *)images parameters:(NSDictionary<NSString *,id> *)parameters outputDescriptors:(NSArray<MTIRenderPipelineOutputDescriptor *> *)outputDescriptors {
    NSParameterAssert(outputDescriptors.count == self.colorAttachmentCount);
    MTIImageRenderingRecipe *receipt = [[MTIImageRenderingRecipe alloc] initWithKernel:self
                                                                           inputImages:images
                                                                    functionParameters:parameters
                                                                     outputDescriptors:outputDescriptors];
    if (self.colorAttachmentCount == 1) {
        MTIImageRenderingRecipeSingleOutputView *promise = [[MTIImageRenderingRecipeSingleOutputView alloc] initWithImageRenderingRecipe:receipt];
        return @[[[MTIImage alloc] initWithPromise:promise]];
    } else {
        NSMutableArray *outputs = [NSMutableArray array];
        for (NSUInteger index = 0; index < outputDescriptors.count; index += 1) {
            MTIImageRenderingRecipeView *promise = [[MTIImageRenderingRecipeView alloc] initWithImageRenderingRecipe:receipt outputIndex:index];
            [outputs addObject:[[MTIImage alloc] initWithPromise:promise]];
        }
        return outputs;
    }
}

@end
