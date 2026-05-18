#import <Cocoa/Cocoa.h>
#import <Speech/Speech.h>
#import <AVFoundation/AVFoundation.h>

// Nova injection dylib:
// 1. Unhides the hidden Lock Split menu item (View > Splits > Lock Split)
// 2. Cmd+L sends @file:line reference to the active terminal
// 3. Hold Fn to dictate voice into the active terminal

#pragma mark - Lock Split

static void unhideLockSplit(void) {
    NSMenu *mainMenu = [NSApp mainMenu];
    if (!mainMenu) return;

    for (NSMenuItem *item in [mainMenu itemArray]) {
        if (![[item title] isEqualToString:@"View"] || ![item hasSubmenu]) continue;
        for (NSMenuItem *sub in [[item submenu] itemArray]) {
            if (![[sub title] isEqualToString:@"Splits"] || ![sub hasSubmenu]) continue;
            for (NSMenuItem *splitItem in [[sub submenu] itemArray]) {
                if ([splitItem action] == @selector(toggleLocked:)) {
                    [splitItem setHidden:NO];
                }
            }
            return;
        }
    }
}

#pragma mark - File Ref to Terminal (Cmd+L)

static NSString *workspacePathFromResponder(NSResponder *r) {
    while (r) {
        @try {
            if ([r respondsToSelector:@selector(workspace)]) {
                id ws = [r valueForKey:@"workspace"];
                if (ws && [ws respondsToSelector:@selector(workspaceURL)]) {
                    NSURL *u = [ws valueForKey:@"workspaceURL"];
                    if (u) return [u path];
                }
            }
        } @catch (NSException *e) {
            NSLog(@"[Nova+] Failed to read workspace from %@: %@", NSStringFromClass([r class]), e);
        }
        r = [r nextResponder];
    }
    return nil;
}

static NSView *findViewBFS(NSView *root, BOOL (^predicate)(NSView *)) {
    NSMutableArray *queue = [NSMutableArray arrayWithObject:root];
    while ([queue count] > 0) {
        NSView *view = [queue firstObject];
        [queue removeObjectAtIndex:0];
        if (predicate(view)) return view;
        [queue addObjectsFromArray:[view subviews]];
    }
    return nil;
}

static NSString *relativePath(NSString *absPath, NSString *wsPath) {
    if (wsPath && [absPath hasPrefix:wsPath]) {
        NSString *suffix = [absPath substringFromIndex:[wsPath length]];
        if ([suffix hasPrefix:@"/"]) suffix = [suffix substringFromIndex:1];
        return suffix;
    }
    return absPath;
}

@interface NovaFileRefHandler : NSObject
+ (void)sendFileRefToTerminal:(id)sender;
@end

@implementation NovaFileRefHandler

+ (NSString *)activeEditorFileLineForWindow:(NSWindow *)keyWindow {

    NSResponder *firstResponder = [keyWindow firstResponder];
    if (!firstResponder) return nil;

    // --- Sidebar case: outline view with selected files/folders ---
    NSOutlineView *outline = nil;
    if ([firstResponder isKindOfClass:[NSOutlineView class]]) {
        outline = (NSOutlineView *)firstResponder;
    } else if (![NSStringFromClass([firstResponder class]) containsString:@"CodeTextView"]) {
        outline = (NSOutlineView *)findViewBFS([keyWindow contentView], ^BOOL(NSView *v) {
            return [v isKindOfClass:[NSOutlineView class]] && [(NSOutlineView *)v selectedRow] >= 0;
        });
    }

    if (outline) {
        NSMutableArray *paths = [NSMutableArray array];
        [[outline selectedRowIndexes] enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
            @try {
                NSString *p = [[outline itemAtRow:(NSInteger)idx] valueForKey:@"path"];
                if (p) [paths addObject:p];
            } @catch (NSException *e) {
                NSLog(@"[Nova+] Failed to read path from sidebar item: %@", e);
            }
        }];

        if ([paths count] > 0) {
            NSString *wsPath = workspacePathFromResponder(firstResponder);
            NSMutableArray *refs = [NSMutableArray array];
            for (NSString *p in paths) {
                [refs addObject:[NSString stringWithFormat:@"@%@", relativePath(p, wsPath)]];
            }
            return [[refs componentsJoinedByString:@" "] stringByAppendingString:@" "];
        }
    }

    // --- Editor case: get line numbers and file path ---
    NSUInteger lineNumber = 1;
    NSUInteger endLineNumber = 0;

    @try {
        if ([firstResponder respondsToSelector:@selector(selectedRange)]) {
            NSRange sel = [(id)firstResponder selectedRange];
            NSString *text = nil;
            if ([firstResponder respondsToSelector:@selector(textStorage)]) {
                id ts = [(id)firstResponder textStorage];
                if (ts) text = [ts string];
            }
            if (text && sel.location <= [text length]) {
                for (NSUInteger i = 0; i < sel.location; i++) {
                    if ([text characterAtIndex:i] == '\n') lineNumber++;
                }
                if (sel.length > 0) {
                    endLineNumber = lineNumber;
                    NSUInteger end = MIN(NSMaxRange(sel), [text length]);
                    for (NSUInteger i = sel.location; i < end; i++) {
                        if ([text characterAtIndex:i] == '\n') endLineNumber++;
                    }
                    if (endLineNumber == lineNumber) endLineNumber = 0;
                }
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[Nova+] Failed to read editor state: %@", e);
    }

    NSString *filePath = nil;
    NSResponder *r = firstResponder;
    while (r) {
        @try {
            if ([r respondsToSelector:@selector(document)]) {
                id doc = [r valueForKey:@"document"];
                if (doc && [doc respondsToSelector:@selector(fileURL)]) {
                    NSURL *url = [doc valueForKey:@"fileURL"];
                    if (url) { filePath = [url path]; break; }
                }
            }
        } @catch (NSException *e) {
            NSLog(@"[Nova+] Failed to read document from %@: %@", NSStringFromClass([r class]), e);
        }
        r = [r nextResponder];
    }

    if (!filePath) return nil;

    NSString *wsPath = workspacePathFromResponder(firstResponder);
    NSString *ref = relativePath(filePath, wsPath);
    if (endLineNumber > 0) {
        return [NSString stringWithFormat:@"@%@:%lu-%lu ", ref, (unsigned long)lineNumber, (unsigned long)endLineNumber];
    }
    return [NSString stringWithFormat:@"@%@:%lu ", ref, (unsigned long)lineNumber];
}

+ (void)sendFileRefToTerminal:(id)sender {
    NSWindow *keyWindow = [NSApp keyWindow];
    if (!keyWindow) { NSBeep(); return; }

    NSString *ref = [self activeEditorFileLineForWindow:keyWindow];
    if (!ref) { NSBeep(); return; }

    NSView *terminal = findViewBFS([keyWindow contentView], ^BOOL(NSView *v) {
        return [NSStringFromClass([v class]) containsString:@"PMTTerminalView"];
    });
    if (terminal) {
        [keyWindow makeFirstResponder:terminal];
        [(id)terminal insertText:ref];
    }
}

@end

#pragma mark - Voice Dictation (Hold Fn)

@interface NovaDictationHandler : NSObject
@property (nonatomic, strong) SFSpeechRecognizer *recognizer;
@property (nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *request;
@property (nonatomic, strong) SFSpeechRecognitionTask *recognitionTask;
@property (nonatomic, strong) AVAudioEngine *audioEngine;
@property (nonatomic, assign) BOOL isRecording;
@property (nonatomic, copy) NSString *lastTranscription;
+ (instancetype)shared;
- (void)startRecording;
- (void)stopRecordingAndInsert;
@end

@implementation NovaDictationHandler

+ (instancetype)shared {
    static NovaDictationHandler *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[NovaDictationHandler alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _recognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale currentLocale]];
        _audioEngine = [[AVAudioEngine alloc] init];
        _isRecording = NO;
    }
    return self;
}

- (void)requestPermissionsIfNeeded {
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        if (status != SFSpeechRecognizerAuthorizationStatusAuthorized) {
            NSLog(@"[Nova+] Speech recognition not authorized: %ld", (long)status);
        }
    }];
}

- (void)startRecording {
    if (self.isRecording) return;
    if (!self.recognizer.isAvailable) {
        NSLog(@"[Nova+] Speech recognizer not available");
        NSBeep();
        return;
    }

    self.lastTranscription = nil;
    self.request = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
    self.request.shouldReportPartialResults = YES;

    AVAudioInputNode *inputNode = self.audioEngine.inputNode;
    AVAudioFormat *format = [inputNode outputFormatForBus:0];

    self.recognitionTask = [self.recognizer recognitionTaskWithRequest:self.request resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
        if (result) {
            self.lastTranscription = result.bestTranscription.formattedString;
        }
        if (error) {
            NSLog(@"[Nova+] Recognition error: %@", error.localizedDescription);
        }
    }];

    [inputNode installTapOnBus:0 bufferSize:1024 format:format block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        [self.request appendAudioPCMBuffer:buffer];
    }];

    NSError *err = nil;
    [self.audioEngine prepare];
    [self.audioEngine startAndReturnError:&err];
    if (err) {
        NSLog(@"[Nova+] Audio engine failed to start: %@", err.localizedDescription);
        NSBeep();
        return;
    }

    self.isRecording = YES;
    NSLog(@"[Nova+] Dictation started");
}

- (void)stopRecordingAndInsert {
    if (!self.isRecording) return;

    [self.audioEngine.inputNode removeTapOnBus:0];
    [self.audioEngine stop];
    [self.request endAudio];
    self.isRecording = NO;
    NSLog(@"[Nova+] Dictation stopped");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSString *text = self.lastTranscription;
        if (!text || [text length] == 0) {
            NSLog(@"[Nova+] No transcription result");
            return;
        }

        NSWindow *keyWindow = [NSApp keyWindow];
        if (!keyWindow) return;

        NSView *terminal = findViewBFS([keyWindow contentView], ^BOOL(NSView *v) {
            return [NSStringFromClass([v class]) containsString:@"PMTTerminalView"];
        });
        if (terminal) {
            [keyWindow makeFirstResponder:terminal];
            [(id)terminal insertText:text];
        }

        self.recognitionTask = nil;
        self.request = nil;
    });
}

@end

#pragma mark - Setup

static void installFileRefShortcut(void) {
    // Remove Cmd+L from Nova's built-in Select Line
    for (NSMenuItem *item in [[NSApp mainMenu] itemArray]) {
        if (![item hasSubmenu]) continue;
        for (NSMenuItem *sub in [[item submenu] itemArray]) {
            if ([sub action] == @selector(selectLine:) &&
                [[sub keyEquivalent] isEqualToString:@"l"] &&
                ([sub keyEquivalentModifierMask] & NSEventModifierFlagCommand)) {
                [sub setKeyEquivalent:@""];
            }
            if ([sub hasSubmenu]) {
                for (NSMenuItem *subsub in [[sub submenu] itemArray]) {
                    if ([subsub action] == @selector(selectLine:) &&
                        [[subsub keyEquivalent] isEqualToString:@"l"]) {
                        [subsub setKeyEquivalent:@""];
                    }
                }
            }
        }
    }

    // Event monitor for Cmd+L (file ref to terminal)
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        NSEventModifierFlags flags = [event modifierFlags];
        if (!(flags & NSEventModifierFlagCommand)) return event;
        if (flags & (NSEventModifierFlagShift | NSEventModifierFlagOption | NSEventModifierFlagControl)) return event;
        if (![[event charactersIgnoringModifiers] isEqualToString:@"l"]) return event;

        [NovaFileRefHandler sendFileRefToTerminal:nil];
        return nil;
    }];
}

static void installDictation(void) {
    [[NovaDictationHandler shared] requestPermissionsIfNeeded];

    // Fn key sends flagsChanged events with no character — detect via modifier flags
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskFlagsChanged handler:^NSEvent *(NSEvent *event) {
        // Fn key is indicated by NSEventModifierFlagFunction
        BOOL fnDown = ([event modifierFlags] & NSEventModifierFlagFunction) != 0;
        // Ignore if other modifiers are held
        NSEventModifierFlags otherMods = NSEventModifierFlagCommand | NSEventModifierFlagOption |
                                         NSEventModifierFlagControl | NSEventModifierFlagShift;
        if ([event modifierFlags] & otherMods) return event;

        NovaDictationHandler *handler = [NovaDictationHandler shared];
        if (fnDown && !handler.isRecording) {
            [handler startRecording];
        } else if (!fnDown && handler.isRecording) {
            [handler stopRecordingAndInsert];
        }
        return event;
    }];
}

__attribute__((constructor))
static void novaInjectInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        unhideLockSplit();
        installFileRefShortcut();
        installDictation();
    });
}
