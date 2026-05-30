#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Nova injection dylib:
// 1. Unhides the hidden Lock Split menu item (View > Splits > Lock Split)
// 2. Cmd+L sends @file:line reference to the active terminal
// 3. Fixes macOS system dictation in the terminal view

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

#pragma mark - Fix System Dictation in Terminal

// PMTCanvas is the actual first responder in Nova's terminal. Its selectedRange returns
// {NSNotFound, 0} which prevents macOS dictation from activating. We fix that and
// suppress setMarkedText: (which renders whitespace garbage during dictation streaming).

static void patchTerminalDictation(void) {
    Class canvasClass = NSClassFromString(@"PMTCanvas");
    if (!canvasClass) return;

    // Fix selectedRange - must return valid position for dictation to activate
    Method selRangeMethod = class_getInstanceMethod(canvasClass, @selector(selectedRange));
    if (selRangeMethod) {
        method_setImplementation(selRangeMethod, imp_implementationWithBlock(^NSRange(id self) {
            return NSMakeRange(0, 0);
        }));
    }

    // Suppress setMarkedText: to prevent whitespace during dictation streaming
    Method canvasSetMarked = class_getInstanceMethod(canvasClass, @selector(setMarkedText:selectedRange:replacementRange:));
    if (canvasSetMarked) {
        method_setImplementation(canvasSetMarked, imp_implementationWithBlock(^(id self, id string, NSRange selectedRange, NSRange replacementRange) {
        }));
    }

    NSLog(@"[Nova+] Patched PMTCanvas for system dictation");
}

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

__attribute__((constructor))
static void novaInjectInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        unhideLockSplit();
        installFileRefShortcut();
        patchTerminalDictation();
    });
}
