#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

// Nova injection dylib:
// 1. Unhides the hidden Lock Split menu item (View > Splits > Lock Split)
// 2. Cmd+L sends @file:line reference to the active terminal
// 3. Cmd+Shift+L locks the focused split

#pragma mark - Lock Split

static void unhideLockSplit(void) {
    NSMenu *mainMenu = [NSApp mainMenu];
    if (!mainMenu) return;

    for (NSMenuItem *item in [mainMenu itemArray]) {
        if (![[item title] isEqualToString:@"View"] || ![item hasSubmenu]) continue;
        for (NSMenuItem *sub in [[item submenu] itemArray]) {
            if (![[sub title] isEqualToString:@"Splits"] || ![sub hasSubmenu]) continue;
            for (NSMenuItem *splitItem in [[sub submenu] itemArray]) {
                if ([splitItem action] == @selector(toggleLocked:) && [splitItem isHidden]) {
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
        } @catch (NSException *e) {}
        r = [r nextResponder];
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

+ (NSString *)activeEditorFileLine {
    NSWindow *keyWindow = [NSApp keyWindow];
    if (!keyWindow) return nil;

    NSResponder *firstResponder = [keyWindow firstResponder];
    if (!firstResponder) return nil;

    // --- Sidebar case: outline view with selected files/folders ---
    NSOutlineView *outline = nil;
    if ([firstResponder isKindOfClass:[NSOutlineView class]]) {
        outline = (NSOutlineView *)firstResponder;
    } else if (![NSStringFromClass([firstResponder class]) containsString:@"CodeTextView"]) {
        NSMutableArray *queue = [NSMutableArray arrayWithObject:[keyWindow contentView]];
        while ([queue count] > 0) {
            NSView *view = [queue firstObject];
            [queue removeObjectAtIndex:0];
            if ([view isKindOfClass:[NSOutlineView class]] && [(NSOutlineView *)view selectedRow] >= 0) {
                outline = (NSOutlineView *)view;
                break;
            }
            [queue addObjectsFromArray:[view subviews]];
        }
    }

    if (outline) {
        NSMutableArray *paths = [NSMutableArray array];
        [[outline selectedRowIndexes] enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
            @try {
                NSString *p = [[outline itemAtRow:(NSInteger)idx] valueForKey:@"path"];
                if (p) [paths addObject:p];
            } @catch (NSException *e) {}
        }];

        if ([paths count] > 0) {
            NSString *wsPath = workspacePathFromResponder(firstResponder);
            NSMutableArray *refs = [NSMutableArray array];
            for (NSString *p in paths) {
                [refs addObject:[NSString stringWithFormat:@"@%@", relativePath(p, wsPath)]];
            }
            return [refs componentsJoinedByString:@" "];
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
    } @catch (NSException *e) {}

    NSString *filePath = nil;
    NSString *wsPath = nil;
    NSResponder *r = firstResponder;
    while (r) {
        if (!filePath) {
            @try {
                if ([r respondsToSelector:@selector(document)]) {
                    id doc = [r valueForKey:@"document"];
                    if (doc && [doc respondsToSelector:@selector(fileURL)]) {
                        NSURL *url = [doc valueForKey:@"fileURL"];
                        if (url) filePath = [url path];
                    }
                }
            } @catch (NSException *e) {}
        }
        if (!wsPath) {
            @try {
                if ([r respondsToSelector:@selector(workspace)]) {
                    id ws = [r valueForKey:@"workspace"];
                    if (ws && [ws respondsToSelector:@selector(workspaceURL)]) {
                        NSURL *u = [ws valueForKey:@"workspaceURL"];
                        if (u) wsPath = [u path];
                    }
                }
            } @catch (NSException *e) {}
        }
        if (filePath && wsPath) break;
        r = [r nextResponder];
    }

    if (!filePath) return nil;

    NSString *ref = relativePath(filePath, wsPath);
    if (endLineNumber > 0) {
        return [NSString stringWithFormat:@"@%@:%lu-%lu", ref, (unsigned long)lineNumber, (unsigned long)endLineNumber];
    }
    return [NSString stringWithFormat:@"@%@:%lu", ref, (unsigned long)lineNumber];
}

+ (void)typeIntoTerminal:(NSString *)text {
    NSWindow *keyWindow = [NSApp keyWindow];
    if (!keyWindow) return;

    NSMutableArray *queue = [NSMutableArray arrayWithObject:[keyWindow contentView]];
    while ([queue count] > 0) {
        NSView *view = [queue firstObject];
        [queue removeObjectAtIndex:0];
        if ([NSStringFromClass([view class]) containsString:@"PMTTerminalView"]) {
            [keyWindow makeFirstResponder:view];
            [(id)view insertText:text];
            return;
        }
        [queue addObjectsFromArray:[view subviews]];
    }
}

+ (void)sendFileRefToTerminal:(id)sender {
    NSString *ref = [self activeEditorFileLine];
    if (!ref) { NSBeep(); return; }
    [self typeIntoTerminal:ref];
}

@end

#pragma mark - Setup

static void installKeyboardHandlers(void) {
    // Remove Cmd+L from Nova's built-in Select Line
    NSMenu *mainMenu = [NSApp mainMenu];
    if (mainMenu) {
        for (NSMenuItem *item in [mainMenu itemArray]) {
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

        // Add menu item to Editor menu for discoverability
        for (NSMenuItem *item in [mainMenu itemArray]) {
            if (![[item title] isEqualToString:@"Editor"] || ![item hasSubmenu]) continue;
            NSMenu *editorMenu = [item submenu];
            [editorMenu addItem:[NSMenuItem separatorItem]];
            NSMenuItem *refItem = [[NSMenuItem alloc] initWithTitle:@"Send File Ref to Terminal"
                                                            action:@selector(sendFileRefToTerminal:)
                                                     keyEquivalent:@""];
            [refItem setTarget:[NovaFileRefHandler class]];
            [editorMenu addItem:refItem];
            break;
        }
    }

    // Single event monitor for both shortcuts
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        if (!([event modifierFlags] & NSEventModifierFlagCommand)) return event;
        if ([event modifierFlags] & (NSEventModifierFlagOption | NSEventModifierFlagControl)) return event;
        if (![[event charactersIgnoringModifiers] isEqualToString:@"l"]) return event;

        if (!([event modifierFlags] & NSEventModifierFlagShift)) {
            [NovaFileRefHandler sendFileRefToTerminal:nil];
            return nil;
        } else {
            [NSApp sendAction:@selector(toggleLocked:) to:nil from:nil];
            return nil;
        }
    }];
}

__attribute__((constructor))
static void novaInjectInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        unhideLockSplit();
        installKeyboardHandlers();
    });
}
