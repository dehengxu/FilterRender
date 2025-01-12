//
//  HYRenderer.m
//  FilterRender
//
//  Created by liuhongyang on 2021/1/25.
//  Copyright © 2021 Burning. All rights reserved.
//

#import "HYRenderer.h"
#import <GPUImage.h>
#import <OpenGLES/ES2/gl.h>
#import "GPUImageGreenScreenFilter.h"

typedef NS_ENUM(NSInteger,HYRendererGreenScreenType){
    HYRendererGreenScreenTypeNone,
    HYRendererGreenScreenTypePicture,
    HYRendererGreenScreenTypeVideo,
};

@interface HYRenderer ()<GPUImageTextureOutputDelegate>
{
    GLProgram *normalProgram;
    GLint positionAttribute;
    GLint textureCoordinateAttribute;
    GLint inputTextureUniform;
}
@property (nonatomic, strong) GPUImageRawDataInput *dataInput;
@property (nonatomic, strong) GPUImageTextureOutput *textureOutput;
@property (nonatomic, strong) GPUImageGreenScreenFilter *blendFilter;
@property (nonatomic, strong) GPUImageFilter *filter;
//@property (nonatomic, strong) GPUImageToonFilter *filter;
@property (nonatomic, strong) GPUImagePicture *inputPicture;
@property (nonatomic, strong) GPUImageMovie *gpuMovie;

@property (nonatomic,assign) HYRendererGreenScreenType greenScreenType;

@property (nonatomic, assign) CVOpenGLESTextureCacheRef textureCache;
@property (nonatomic, assign) CVOpenGLESTextureRef renderTexture;
@property (nonatomic, assign) GLuint VBO;

@end

@implementation HYRenderer


- (id)init {
    self = [super init];
    if (self) {
        [self setupNormalProgram];
        [self setupFilters];
    }
    return self;
}

- (void)setupFilters{
    self.dataInput = [[GPUImageRawDataInput alloc] initWithBytes:nil size:CGSizeZero pixelFormat:GPUPixelFormatBGRA type:GPUPixelTypeUByte];
    self.filter = [[GPUImageFilter alloc] init];
    self.blendFilter = [[GPUImageGreenScreenFilter alloc] init];
    self.textureOutput = [[GPUImageTextureOutput alloc] init];
    self.textureOutput.delegate = self;
    self.greenScreenType = HYRendererGreenScreenTypeNone;
}

- (void)showGreenScreenWithImage:(UIImage *)image{
    self.inputPicture = [[GPUImagePicture alloc] initWithImage:image smoothlyScaleOutput:YES];
    self.greenScreenType = HYRendererGreenScreenTypePicture;
}

- (void)showGreenScreenWithVideoUrl:(NSURL *)videoUrl{
    self.gpuMovie = [[GPUImageMovie alloc] initWithURL:videoUrl];
    self.gpuMovie.playAtActualSpeed = YES;
    self.gpuMovie.shouldRepeat = YES;
    self.greenScreenType = HYRendererGreenScreenTypeVideo;
}

- (void)setGreenScreenType:(HYRendererGreenScreenType)greenScreenType
{
    _greenScreenType = greenScreenType;
    
    [self.dataInput removeAllTargets];
    [self.filter removeAllTargets];
    [self.inputPicture removeAllTargets];
    [self.gpuMovie removeAllTargets];
    
    switch (greenScreenType) {
        case HYRendererGreenScreenTypeNone:{
            [self.dataInput addTarget:self.filter];
            [self.filter addTarget:self.textureOutput];
        }break;
        case HYRendererGreenScreenTypePicture:{
            [self.dataInput addTarget:self.blendFilter];
            [self.inputPicture addTarget:self.blendFilter];
            [self.blendFilter addTarget:self.filter];
            [self.filter addTarget:self.textureOutput];
            runSynchronouslyOnVideoProcessingQueue(^{
                [self.gpuMovie cancelProcessing];
                [self.inputPicture processImage];
            });

        }break;
        case HYRendererGreenScreenTypeVideo:{
            [self.dataInput addTarget:self.blendFilter];
            [self.gpuMovie addTarget:self.blendFilter];
            [self.blendFilter addTarget:self.filter];
            [self.filter addTarget:self.textureOutput];
            runSynchronouslyOnVideoProcessingQueue(^{
                [self.gpuMovie startProcessing];
            });
        }break;
            
        default:
            break;
    }
}

- (void)cleanGreenScreen{
    self.greenScreenType = HYRendererGreenScreenTypeNone;
    if (self.inputPicture) {
        [self.inputPicture removeAllTargets];
        self.inputPicture = nil;
    }
    if (self.gpuMovie) {
        [self.gpuMovie removeAllTargets];
        [self.gpuMovie cancelProcessing];
        self.gpuMovie = nil;
    }
}

- (void)setupNormalProgram {
    runSynchronouslyOnVideoProcessingQueue(^{
        [GPUImageContext useImageProcessingContext];
        
        self->normalProgram = [[GPUImageContext sharedImageProcessingContext] programForVertexShaderString:kGPUImageVertexShaderString fragmentShaderString:kGPUImagePassthroughFragmentShaderString];
        if (!self->normalProgram.initialized) {
            [self->normalProgram addAttribute:@"position"];
            [self->normalProgram addAttribute:@"inputTextureCoordinate"];
            if (![self->normalProgram link]) {
                NSString *progLog = [self->normalProgram programLog];
                NSLog(@"program link log:%@",progLog);
                NSString *fragLog = [self->normalProgram fragmentShaderLog];
                NSLog(@"program link log:%@",fragLog);
                NSString *vertexLog = [self->normalProgram vertexShaderLog];
                NSLog(@"program link log:%@",vertexLog);
            }
            self->positionAttribute = [self->normalProgram attributeIndex:@"position"];
            self->textureCoordinateAttribute = [self->normalProgram attributeIndex:@"inputTextureCoordinate"];
            self->inputTextureUniform = [self->normalProgram uniformIndex:@"inputImageTexture"];
            
            [GPUImageContext setActiveShaderProgram:self->normalProgram];
            glEnableVertexAttribArray(self->positionAttribute);
            glEnableVertexAttribArray(self->textureCoordinateAttribute);
        }
    });
}

- (CVPixelBufferRef)renderPixelBuffer:(CVPixelBufferRef)pixelBuffer{
    if (!pixelBuffer) {
        return nil;
    }
    CVPixelBufferRetain(pixelBuffer);
    runSynchronouslyOnVideoProcessingQueue(^{
        [GPUImageContext useImageProcessingContext];
        
        CGSize size = CGSizeMake(CVPixelBufferGetWidth(pixelBuffer),
                                 CVPixelBufferGetHeight(pixelBuffer));
        
        CVPixelBufferLockBaseAddress(pixelBuffer, 0);
        void *bytes = CVPixelBufferGetBaseAddress(pixelBuffer);
        [self.dataInput updateDataFromBytes:bytes size:size];
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        
        [self.dataInput processData];
        GLuint textureId = self.textureOutput.texture;
        [self convertTextureId:textureId textureSize:size pixelBuffer:pixelBuffer];
    });
    CVPixelBufferRelease(pixelBuffer);
    return pixelBuffer;
}

- (void)newFrameReadyFromTextureOutput:(GPUImageTextureOutput *)callbackTextureOutput{
    [self.textureOutput doneWithTexture];
}

- (CVPixelBufferRef)convertTextureId:(GLuint)textureId
                         textureSize:(CGSize)textureSize
                         pixelBuffer:(CVPixelBufferRef)pixelBuffer{
    
    [GPUImageContext useImageProcessingContext];
    [self cleanUpTextures];

    GLuint frameBuffer;
    glGenFramebuffers(1, &frameBuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, frameBuffer);
    // texture
    GLuint targetTextureID = [self convertRGBPixelBufferToTexture:pixelBuffer];
    glBindTexture(GL_TEXTURE_2D, targetTextureID);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, textureSize.width, textureSize.height, 0, GL_BGRA, GL_UNSIGNED_BYTE, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, targetTextureID, 0);
    glViewport(0, 0, textureSize.width, textureSize.height);
    
    [self renderTextureWithId:textureId];
    
    glDeleteFramebuffers(1, &frameBuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    
    glFlush();
    
    return pixelBuffer;
}

- (void)renderTextureWithId:(GLuint)textureId{
    [GPUImageContext setActiveShaderProgram:self->normalProgram];
    
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, textureId);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glUniform1i(self->inputTextureUniform,0);
    
    static const GLfloat squareVertices[] = {
        -1.0f, -1.0f,
        1.0f, -1.0f,
        -1.0f, 1.0f,
        1.0f, 1.0f,
    };
    glVertexAttribPointer(self->positionAttribute, 2, GL_FLOAT, GL_FALSE, 0, squareVertices);
    glVertexAttribPointer(self->textureCoordinateAttribute, 2, GL_FLOAT, GL_FALSE, 0, [GPUImageFilter textureCoordinatesForRotation:kGPUImageNoRotation]);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

- (void)cleanUpTextures
{
    if (_renderTexture) {
        CFRelease(_renderTexture);
        _renderTexture = NULL;
    }
    CVOpenGLESTextureCacheFlush([[GPUImageContext sharedImageProcessingContext] coreVideoTextureCache], 0);
}

- (GLuint)convertRGBPixelBufferToTexture:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) {
        return 0;
    }
    CGSize textureSize = CGSizeMake(CVPixelBufferGetWidth(pixelBuffer),
                                    CVPixelBufferGetHeight(pixelBuffer));
    CVOpenGLESTextureRef texture = nil;
	CVReturn status = CVOpenGLESTextureCacheCreateTextureFromImage(nil,
																   [[GPUImageContext sharedImageProcessingContext] coreVideoTextureCache],
																   pixelBuffer,
																   nil,
																   GL_TEXTURE_2D,
																   GL_RGBA,
																   textureSize.width,
																   textureSize.height,
																   GL_BGRA,
																   GL_UNSIGNED_BYTE,
																   0,
																   &texture);
    
    if (status != kCVReturnSuccess) {
        NSLog(@"Can't create texture");
    }
    self.renderTexture = texture;
    return CVOpenGLESTextureGetName(texture);
}

@end
