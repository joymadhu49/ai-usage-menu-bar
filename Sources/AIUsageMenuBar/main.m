// AI Usage Menu Bar
// One macOS menu-bar app that shows BOTH Claude Code usage and Codex usage
// side by side. Claude data comes from the Claude Code keychain login + the
// Anthropic OAuth usage API; Codex data comes from the Codex app-server
// (`codex app-server --stdio`, account/rateLimits/read) with a fallback to the
// most recent `token_count` snapshot in ~/.codex/sessions/*.jsonl.

#import <Cocoa/Cocoa.h>
#import <ServiceManagement/ServiceManagement.h>
#import <Security/Security.h>
#import <UserNotifications/UserNotifications.h>
#import <math.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>

#pragma mark - Defaults keys

static NSString * const DisplayModeKey = @"displayMode";
static NSString * const DisplayModePercent = @"percent";
static NSString * const DisplayModeBattery = @"battery";

static NSString * const MetricModeKey = @"metricMode";
static NSString * const MetricModeLeft = @"left";
static NSString * const MetricModeUsed = @"used";

static NSString * const TimeModeKey = @"timeMode";
static NSString * const TimeModeClock = @"clock";
static NSString * const TimeModeCountdown = @"countdown";

static NSString * const ClaudeWindowKey = @"claudeWindow";
static NSString * const ClaudeWindowSession = @"session"; // 5h  -> primary
static NSString * const ClaudeWindowWeekly = @"weekly";   // 7d  -> secondary

static NSString * const CodexWindowKey = @"codexWindow";
static NSString * const CodexWindowDaily = @"daily";   // primary
static NSString * const CodexWindowWeekly = @"weekly"; // secondary

static NSString * const ShowClaudeKey = @"showClaude";
static NSString * const ShowCodexKey = @"showCodex";
static NSString * const ShowTimeInBarKey = @"showTimeInBar";

static NSString * const RefreshIntervalKey = @"refreshIntervalSeconds";
static NSTimeInterval const DefaultRefreshIntervalSeconds = 300.0;

// Usage alerts: notify once when the tracked window crosses 80%, again at 95%,
// re-armed once usage falls back below 75% (hysteresis so resets re-arm cleanly).
static NSString * const AlertsEnabledKey = @"alertsEnabled";
static NSString * const ClaudeNotifyLevelKey = @"claudeNotifyLevel";
static NSString * const CodexNotifyLevelKey = @"codexNotifyLevel";

// Rolling 24h of usage samples for the sparkline rows: array of
// {t: epoch, c: claude 5h used% (-1 when unknown), x: codex primary used%}.
static NSString * const HistoryKey = @"usageHistory";
static NSTimeInterval const HistoryWindowSeconds = 24.0 * 3600.0;

// LAN sync server for the iOS companion app: serves the latest provider
// states as JSON on this port and announces itself over Bonjour so the
// iPhone can find this Mac automatically. Usage percentages only — no
// tokens or credentials ever leave the machine.
static NSString * const SyncServerEnabledKey = @"syncServerEnabled";
static uint16_t const SyncServerPort = 8737;
static NSString * const SyncServiceType = @"_aiusage._tcp.";

// Persisted last-good Claude snapshot, so the bar keeps showing real numbers
// even while the API is unreachable or rate-limiting us.
static NSString * const ClaudeLastGoodStateKey = @"claudeLastGoodState";
static NSString * const ClaudeLastGoodFetchedAtKey = @"claudeLastGoodFetchedAt";
static NSTimeInterval const UsageBackoffMaxSeconds = 600.0;

// Claude Code OAuth configuration (matches the Claude Code CLI production config).
// Credentials are resolved file-first (~/.claude/.credentials.json, kept fresh by
// the CLI) so the app never has to touch the CLI's keychain item in normal use.
// The keychain is a one-time last resort: reading another app's item triggers a
// password prompt, and because this app is ad-hoc signed, "Always Allow" cannot
// stick across rebuilds — so we avoid the keychain rather than fight it.
static NSString * const KeychainService = @"Claude Code-credentials";
static NSString * const OAuthClientID = @"9d1c250a-e61b-44d9-88ed-5944d1962f5e";
static NSString * const OAuthTokenURL = @"https://platform.claude.com/v1/oauth/token";
static NSString * const ClaudeUsageURL = @"https://api.anthropic.com/api/oauth/usage";
static NSString * const OAuthBetaHeader = @"oauth-2025-04-20";

#pragma mark - Custom menu row views

static CGFloat const AIMRowWidth = 306.0;
static CGFloat const AIMRowLeftInset = 14.0;
static CGFloat const AIMRowRightInset = 14.0;
static CGFloat const AIMTrackLeft = 58.0;

// Tints a template image into `rect` with `color` (menu views don't auto-tint).
static void AIMDrawTemplateImage(NSImage *image, NSRect rect, NSColor *color) {
    if (image == nil) { return; }
    [image drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
    [color set];
    NSRectFillUsingOperation(rect, NSCompositingOperationSourceAtop);
}

// A provider section header: icon + bold name on the left, a faint plan/status
// pill on the right.
@interface AIMHeaderRow : NSView
@property(nonatomic, strong) NSImage *icon;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *trailing;
@end

@implementation AIMHeaderRow
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect b = self.bounds;
    CGFloat midY = NSMidY(b);

    if (self.icon != nil) {
        AIMDrawTemplateImage(self.icon, NSMakeRect(AIMRowLeftInset, midY - 7.0, 14.0, 14.0), NSColor.labelColor);
    }

    NSDictionary *titleAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: NSColor.labelColor
    };
    NSSize ts = [self.title sizeWithAttributes:titleAttrs];
    [self.title drawAtPoint:NSMakePoint(AIMRowLeftInset + 20.0, midY - ts.height / 2.0) withAttributes:titleAttrs];

    if (self.trailing.length > 0) {
        NSDictionary *pillAttrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:9.5 weight:NSFontWeightSemibold],
            NSForegroundColorAttributeName: NSColor.secondaryLabelColor
        };
        NSSize ps = [self.trailing sizeWithAttributes:pillAttrs];
        CGFloat padX = 6.0, padY = 1.5;
        NSRect pill = NSMakeRect(NSMaxX(b) - AIMRowRightInset - ps.width - padX * 2.0,
                                 midY - ps.height / 2.0 - padY,
                                 ps.width + padX * 2.0, ps.height + padY * 2.0);
        NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:pill xRadius:pill.size.height / 2.0 yRadius:pill.size.height / 2.0];
        [[NSColor.secondaryLabelColor colorWithAlphaComponent:0.14] set];
        [bg fill];
        [self.trailing drawAtPoint:NSMakePoint(pill.origin.x + padX, midY - ps.height / 2.0) withAttributes:pillAttrs];
    }
}
@end

// A usage row: window label, a rounded progress track filled to `usedPercent`,
// and a right-aligned value string (e.g. "97% left · 2:00 PM").
@interface AIMUsageRow : NSView
@property(nonatomic, copy) NSString *label;
@property(nonatomic, assign) double usedPercent; // NAN when unknown
@property(nonatomic, copy) NSString *valueText;
@end

@implementation AIMUsageRow
- (NSColor *)severityColor:(double)used {
    if (used >= 90.0) { return NSColor.systemRedColor; }
    if (used >= 75.0) { return NSColor.systemOrangeColor; }
    return NSColor.systemGreenColor;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect b = self.bounds;
    CGFloat midY = NSMidY(b);

    NSDictionary *labelAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: NSColor.secondaryLabelColor
    };
    NSSize ls = [self.label sizeWithAttributes:labelAttrs];
    [self.label drawAtPoint:NSMakePoint(AIMRowLeftInset, midY - ls.height / 2.0) withAttributes:labelAttrs];

    // Two-tone value: the percent reads first, the reset time stays quiet
    // ("97% left" bold label color, " · 11:20 PM" small tertiary).
    NSString *value = self.valueText ?: @"";
    NSMutableAttributedString *att = [[NSMutableAttributedString alloc] initWithString:value attributes:@{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:11.0 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: NSColor.labelColor
    }];
    NSRange sep = [value rangeOfString:@" · "];
    if (sep.location != NSNotFound) {
        [att setAttributes:@{
            NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:10.0 weight:NSFontWeightRegular],
            NSForegroundColorAttributeName: NSColor.tertiaryLabelColor
        } range:NSMakeRange(sep.location, value.length - sep.location)];
    }
    NSSize vs = att.size;
    CGFloat valueRight = NSMaxX(b) - AIMRowRightInset;
    [att drawAtPoint:NSMakePoint(valueRight - vs.width, midY - vs.height / 2.0)];

    CGFloat trackLeft = AIMTrackLeft;
    CGFloat trackRight = valueRight - vs.width - 10.0;
    if (trackRight < trackLeft + 24.0) { trackRight = trackLeft + 24.0; }
    NSRect track = NSMakeRect(trackLeft, midY - 2.0, trackRight - trackLeft, 4.0);
    NSBezierPath *trackPath = [NSBezierPath bezierPathWithRoundedRect:track xRadius:2.0 yRadius:2.0];
    [[NSColor.tertiaryLabelColor colorWithAlphaComponent:0.22] set];
    [trackPath fill];

    if (!isnan(self.usedPercent)) {
        double fraction = MAX(0.0, MIN(100.0, self.usedPercent)) / 100.0;
        CGFloat width = track.size.width * fraction;
        if (fraction > 0.0 && width < 3.0) { width = 3.0; }
        if (width > 0.0) {
            NSRect fill = NSMakeRect(track.origin.x, track.origin.y, width, track.size.height);
            NSBezierPath *fillPath = [NSBezierPath bezierPathWithRoundedRect:fill xRadius:2.0 yRadius:2.0];
            [[self severityColor:self.usedPercent] set];
            [fillPath fill];
        }
    }
}
@end

// A 24h history sparkline: label on the left, a step-line of used% samples
// (0..100 vertically) across the last 24 hours on the right.
@interface AIMSparkRow : NSView
@property(nonatomic, copy) NSString *label;
@property(nonatomic, copy) NSArray<NSDictionary *> *points; // {t: epoch, v: used% 0..100}
@end

@implementation AIMSparkRow
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect b = self.bounds;
    CGFloat midY = NSMidY(b);

    NSDictionary *labelAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: NSColor.secondaryLabelColor
    };
    NSSize ls = [self.label sizeWithAttributes:labelAttrs];
    [self.label drawAtPoint:NSMakePoint(AIMRowLeftInset, midY - ls.height / 2.0) withAttributes:labelAttrs];

    NSRect plot = NSMakeRect(AIMTrackLeft, 3.0, NSMaxX(b) - AIMRowRightInset - AIMTrackLeft, b.size.height - 6.0);
    [[NSColor.tertiaryLabelColor colorWithAlphaComponent:0.10] set];
    [[NSBezierPath bezierPathWithRoundedRect:plot xRadius:3.0 yRadius:3.0] fill];

    if (self.points.count < 2) {
        return;
    }

    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSTimeInterval start = now - HistoryWindowSeconds;
    NSBezierPath *line = [NSBezierPath bezierPath];
    line.lineWidth = 1.25;
    line.lineJoinStyle = NSLineJoinStyleRound;
    BOOL started = NO;
    CGFloat lastY = 0.0;
    for (NSDictionary *p in self.points) {
        double t = [p[@"t"] doubleValue];
        double v = [p[@"v"] doubleValue];
        if (t < start || v < 0.0) { continue; }
        CGFloat px = plot.origin.x + (CGFloat)((t - start) / HistoryWindowSeconds) * plot.size.width;
        CGFloat py = plot.origin.y + 1.0 + (CGFloat)(MIN(100.0, v) / 100.0) * (plot.size.height - 2.0);
        if (!started) {
            [line moveToPoint:NSMakePoint(px, py)];
            started = YES;
        } else {
            // Step line: hold the previous level until this sample's time.
            [line lineToPoint:NSMakePoint(px, lastY)];
            [line lineToPoint:NSMakePoint(px, py)];
        }
        lastY = py;
    }
    if (started) {
        [[NSColor.secondaryLabelColor colorWithAlphaComponent:0.75] set];
        [line stroke];
    }
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSTimer *pollTimer;
@property(nonatomic, strong) NSTimer *displayTimer;

@property(nonatomic, strong) NSDictionary *claudeState;
@property(nonatomic, strong) NSDictionary *codexState;

@property(nonatomic, strong) NSImage *claudeIcon;
@property(nonatomic, strong) NSImage *codexIcon;
@property(nonatomic, copy) NSString *launchAtLoginError;

// Claude network resilience (token refresh throttle, rate-limit cool-down,
// last-good snapshot).
@property(nonatomic, strong) NSDate *refreshBackoffUntil;
@property(nonatomic, strong) NSDictionary *claudeLastGoodState;
@property(nonatomic, strong) NSDate *claudeLastGoodFetchedAt;
@property(nonatomic, strong) NSDate *usageBackoffUntil;
@property(nonatomic, assign) NSTimeInterval usageBackoffSeconds;

// LAN sync server (iOS companion).
@property(nonatomic, assign) int syncListenFD;
@property(nonatomic, strong) dispatch_source_t syncSource;
@property(nonatomic, strong) NSNetService *syncService;

// Token usage aggregates computed from local session logs:
// {today: tokens, today_cost: $, total: tokens, total_cost: $} per provider.
@property(nonatomic, strong) NSDictionary *claudeTokenStats;
@property(nonatomic, strong) NSDictionary *codexTokenStats;
@property(nonatomic, strong) NSMutableDictionary *tokenCache;
@property(nonatomic, strong) NSDictionary *claudeCredsCache;
@property(nonatomic, strong) NSDate *keychainDenyUntil;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        DisplayModeKey: DisplayModePercent,
        MetricModeKey: MetricModeLeft,
        TimeModeKey: TimeModeClock,
        ClaudeWindowKey: ClaudeWindowSession,
        CodexWindowKey: CodexWindowDaily,
        ShowClaudeKey: @YES,
        ShowCodexKey: @YES,
        ShowTimeInBarKey: @NO,
        AlertsEnabledKey: @YES,
        SyncServerEnabledKey: @YES,
        RefreshIntervalKey: @(DefaultRefreshIntervalSeconds)
    }];

    [self restoreClaudeLastGoodState];
    [self requestNotificationAuthorization];
    self.syncListenFD = -1;
    [self startSyncServerIfEnabled];

    self.claudeIcon = [self claudeMenuBarIcon];
    self.codexIcon = [self codexMenuBarIcon];

    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.image = [self barImage];
    self.statusItem.button.imagePosition = NSImageOnly;
    // A permanently attached menu opens natively on BOTH left- and right-click,
    // on mouse-down, with AppKit doing all the tracking. Its items are rebuilt
    // in place via menuNeedsUpdate: just before each open. Never swap
    // statusItem.menu around a click (attach-performClick-detach): detaching
    // can land while the menu is still opening and the click shows nothing.
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"AI Usage"];
    menu.delegate = self;
    self.statusItem.menu = menu;

    [self refresh];
    [self schedulePollTimer];
    self.displayTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                         target:self
                                                       selector:@selector(updateStatusItem)
                                                       userInfo:nil
                                                        repeats:YES];
}

#pragma mark - Icons

// Draws the Claude "sunburst" mark as a set of radial rays, sized to fill rect.
- (void)drawClaudeBurstInRect:(NSRect)rect {
    NSPoint center = NSMakePoint(NSMidX(rect), NSMidY(rect));
    CGFloat unit = MIN(rect.size.width, rect.size.height);
    CGFloat outer = unit * 0.46;
    CGFloat inner = unit * 0.05;
    CGFloat thickness = unit * 0.115;

    NSInteger rays = 12;
    for (NSInteger i = 0; i < rays; i++) {
        double angle = (M_PI * 2.0 * i) / rays - M_PI_2;
        NSPoint p0 = NSMakePoint(center.x + cos(angle) * inner, center.y + sin(angle) * inner);
        NSPoint p1 = NSMakePoint(center.x + cos(angle) * outer, center.y + sin(angle) * outer);
        NSBezierPath *ray = [NSBezierPath bezierPath];
        ray.lineWidth = thickness;
        ray.lineCapStyle = NSLineCapStyleRound;
        [ray moveToPoint:p0];
        [ray lineToPoint:p1];
        [ray stroke];
    }
}

- (NSImage *)claudeMenuBarIcon {
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(16.0, 16.0)];
    [image lockFocus];
    [NSColor.blackColor set];
    [self drawClaudeBurstInRect:NSMakeRect(0.0, 0.0, 16.0, 16.0)];
    [image unlockFocus];
    image.template = YES;
    return image;
}

- (NSImage *)codexMenuBarIcon {
    NSArray<NSString *> *paths = @[
        @"/Applications/Codex.app/Contents/Resources/codexTemplate@2x.png",
        @"/Applications/Codex.app/Contents/Resources/icon-codex-dark.png",
        @"/Applications/Codex.app/Contents/Resources/icon.png"
    ];
    for (NSString *path in paths) {
        NSImage *image = [[NSImage alloc] initWithContentsOfFile:path];
        if (image != nil) {
            image.template = YES;
            image.size = NSMakeSize(16.0, 16.0);
            return image;
        }
    }
    return [self codexFallbackIcon];
}

// A simple ">_" terminal glyph if the Codex app icon isn't installed.
- (NSImage *)codexFallbackIcon {
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(16.0, 16.0)];
    [image lockFocus];
    [NSColor.blackColor set];
    NSBezierPath *chevron = [NSBezierPath bezierPath];
    chevron.lineWidth = 1.6;
    chevron.lineCapStyle = NSLineCapStyleRound;
    chevron.lineJoinStyle = NSLineJoinStyleRound;
    [chevron moveToPoint:NSMakePoint(3.5, 11.5)];
    [chevron lineToPoint:NSMakePoint(7.5, 8.0)];
    [chevron lineToPoint:NSMakePoint(3.5, 4.5)];
    [chevron stroke];
    NSBezierPath *underscore = [NSBezierPath bezierPathWithRect:NSMakeRect(8.5, 4.0, 4.5, 1.6)];
    [underscore fill];
    [image unlockFocus];
    image.template = YES;
    return image;
}

#pragma mark - Status bar rendering (composite image of both providers)

// The bar image is drawn with dynamic colors resolved against the status
// button's appearance (so it adapts to light/dark), which lets us tint a
// provider's readout orange at >=75% used and red at >=90%.
- (void)updateStatusItem {
    NSAppearance *appearance = self.statusItem.button.effectiveAppearance ?: NSApp.effectiveAppearance;
    __block NSImage *image = nil;
    [appearance performAsCurrentDrawingAppearance:^{
        image = [self barImage];
    }];
    self.statusItem.button.image = image;
}

// Orange when the window is >=75% used, red at >=90%, otherwise normal text.
- (NSColor *)barSeverityColorForUsed:(double)used {
    if (!isnan(used) && used >= 90.0) { return NSColor.systemRedColor; }
    if (!isnan(used) && used >= 75.0) { return NSColor.systemOrangeColor; }
    return NSColor.labelColor;
}

// Builds one composite image: [claudeIcon 45%]  [codexIcon 12%]  (+ optional time).
- (NSImage *)barImage {
    BOOL showClaude = [self boolDefault:ShowClaudeKey];
    BOOL showCodex = [self boolDefault:ShowCodexKey];
    BOOL battery = [[self displayMode] isEqualToString:DisplayModeBattery];

    NSMutableArray<NSDictionary *> *readouts = [NSMutableArray array];
    if (showClaude) {
        [readouts addObject:@{
            @"icon": self.claudeIcon ?: [NSNull null],
            @"metric": @([self barMetricForState:self.claudeState secondary:[self claudeUsesSecondary]]),
            @"used": @([self stateOK:self.claudeState] ? [self usedPercentForState:self.claudeState secondary:[self claudeUsesSecondary]] : NAN)
        }];
    }
    if (showCodex) {
        [readouts addObject:@{
            @"icon": self.codexIcon ?: [NSNull null],
            @"metric": @([self barMetricForState:self.codexState secondary:[self codexUsesSecondary]]),
            @"used": @([self stateOK:self.codexState] ? [self usedPercentForState:self.codexState secondary:[self codexUsesSecondary]] : NAN)
        }];
    }
    if (readouts.count == 0) {
        return [self labelImage:@"AI"];
    }

    NSString *timeText = [self boolDefault:ShowTimeInBarKey] ? [self barTimeText] : nil;

    NSFont *font = [NSFont monospacedDigitSystemFontOfSize:12.5 weight:NSFontWeightSemibold];
    NSDictionary *measureAttrs = @{ NSFontAttributeName: font };

    CGFloat height = 18.0;
    CGFloat iconSize = 15.0;
    CGFloat gapIconText = 3.0;
    CGFloat gapProviders = 9.0;
    CGFloat batteryWidth = 30.0;

    // Measure.
    CGFloat width = 2.0;
    NSMutableArray<NSValue *> *metricSizes = [NSMutableArray array];
    for (NSDictionary *r in readouts) {
        width += iconSize + gapIconText;
        if (battery) {
            width += batteryWidth;
            [metricSizes addObject:[NSValue valueWithSize:NSZeroSize]];
        } else {
            NSString *text = [self metricTextForValue:[r[@"metric"] doubleValue]];
            NSSize s = [text sizeWithAttributes:measureAttrs];
            [metricSizes addObject:[NSValue valueWithSize:s]];
            width += s.width;
        }
        width += gapProviders;
    }
    width -= gapProviders; // no trailing gap after last provider
    NSSize timeSize = NSZeroSize;
    if (timeText.length > 0) {
        timeSize = [timeText sizeWithAttributes:measureAttrs];
        width += gapProviders + timeSize.width;
    }
    width += 2.0;

    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(ceil(width), height)];
    [image lockFocus];

    CGFloat x = 2.0;
    for (NSUInteger i = 0; i < readouts.count; i++) {
        NSDictionary *r = readouts[i];
        double used = [r[@"used"] doubleValue];
        NSColor *color = [self barSeverityColorForUsed:used];

        id icon = r[@"icon"];
        if ([icon isKindOfClass:[NSImage class]]) {
            AIMDrawTemplateImage((NSImage *)icon,
                                 NSMakeRect(x, (height - iconSize) / 2.0, iconSize, iconSize),
                                 NSColor.labelColor);
        }
        x += iconSize + gapIconText;

        double metric = [r[@"metric"] doubleValue];
        if (battery) {
            [self drawBatteryInRect:NSMakeRect(x, (height - 12.0) / 2.0, batteryWidth, 12.0)
                            percent:metric
                              color:color];
            x += batteryWidth;
        } else {
            NSString *text = [self metricTextForValue:metric];
            NSSize s = [metricSizes[i] sizeValue];
            [text drawAtPoint:NSMakePoint(x, (height - s.height) / 2.0)
               withAttributes:@{ NSFontAttributeName: font, NSForegroundColorAttributeName: color }];
            x += s.width;
        }
        x += gapProviders;
    }

    if (timeText.length > 0) {
        [timeText drawAtPoint:NSMakePoint(x, (height - timeSize.height) / 2.0)
           withAttributes:@{ NSFontAttributeName: font, NSForegroundColorAttributeName: NSColor.labelColor }];
    }

    [image unlockFocus];
    image.template = NO;
    return image;
}

- (NSImage *)labelImage:(NSString *)label {
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:12.5 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: NSColor.labelColor
    };
    NSSize s = [label sizeWithAttributes:attrs];
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(ceil(s.width) + 4.0, 18.0)];
    [image lockFocus];
    [label drawAtPoint:NSMakePoint(2.0, (18.0 - s.height) / 2.0) withAttributes:attrs];
    [image unlockFocus];
    image.template = NO;
    return image;
}

// Battery glyph with the percent number inside, drawn into the current context.
- (void)drawBatteryInRect:(NSRect)body percent:(double)percent color:(NSColor *)color {
    if (isnan(percent)) {
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:9.0 weight:NSFontWeightSemibold],
            NSForegroundColorAttributeName: NSColor.labelColor
        };
        [@"--" drawAtPoint:NSMakePoint(body.origin.x + 4.0, body.origin.y) withAttributes:attrs];
        return;
    }
    double clamped = MAX(0.0, MIN(100.0, percent));

    [NSColor.labelColor set];
    NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect:body xRadius:2.0 yRadius:2.0];
    outline.lineWidth = 1.4;
    [outline stroke];

    NSRect nub = NSMakeRect(NSMaxX(body) + 1.0, NSMidY(body) - 2.5, 2.0, 5.0);
    [[NSBezierPath bezierPathWithRoundedRect:nub xRadius:0.8 yRadius:0.8] fill];

    CGFloat fillWidth = (CGFloat)((body.size.width - 4.0) * (clamped / 100.0));
    if (fillWidth > 0.5) {
        [(color ?: NSColor.labelColor) set];
        NSRect fillRect = NSMakeRect(body.origin.x + 2.0, body.origin.y + 2.0, fillWidth, body.size.height - 4.0);
        [[NSBezierPath bezierPathWithRoundedRect:fillRect xRadius:1.0 yRadius:1.0] fill];
    }

    NSString *number = [NSString stringWithFormat:@"%.0f", clamped];
    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8.5 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: NSColor.labelColor
    };
    NSSize numberSize = [number sizeWithAttributes:attributes];
    NSPoint numberPoint = NSMakePoint(NSMidX(body) - numberSize.width / 2.0,
                                      NSMidY(body) - numberSize.height / 2.0 - 0.5);
    [number drawAtPoint:numberPoint withAttributes:attributes];
}

- (NSString *)metricTextForValue:(double)value {
    if (isnan(value)) {
        return @"--";
    }
    return [NSString stringWithFormat:@"%.0f%%", value];
}

// The number shown in the bar: % left or % used per the metric mode.
- (double)barMetricForState:(NSDictionary *)state secondary:(BOOL)secondary {
    if (![self stateOK:state]) {
        return NAN;
    }
    double used = [self usedPercentForState:state secondary:secondary];
    if (isnan(used)) {
        return NAN;
    }
    if ([[self metricMode] isEqualToString:MetricModeUsed]) {
        return used;
    }
    return MAX(0.0, MIN(100.0, 100.0 - used));
}

// Soonest reset across the shown providers, as the selected time format.
- (NSString *)barTimeText {
    NSMutableArray<NSNumber *> *resets = [NSMutableArray array];
    if ([self boolDefault:ShowClaudeKey] && [self stateOK:self.claudeState]) {
        NSNumber *r = [self resetSecondsForState:self.claudeState secondary:[self claudeUsesSecondary]];
        if (r != nil) { [resets addObject:r]; }
    }
    if ([self boolDefault:ShowCodexKey] && [self stateOK:self.codexState]) {
        NSNumber *r = [self resetSecondsForState:self.codexState secondary:[self codexUsesSecondary]];
        if (r != nil) { [resets addObject:r]; }
    }
    if (resets.count == 0) {
        return nil;
    }
    NSNumber *soonest = [resets valueForKeyPath:@"@min.self"];
    if ([[self timeMode] isEqualToString:TimeModeCountdown]) {
        return [self countdownTextForSeconds:soonest];
    }
    return [self clockTextForSeconds:soonest];
}

#pragma mark - Generic state accessors (shared by both providers)

- (BOOL)stateOK:(NSDictionary *)state {
    NSNumber *ok = state[@"ok"];
    return [ok respondsToSelector:@selector(boolValue)] && [ok boolValue];
}

- (double)usedPercentForState:(NSDictionary *)state secondary:(BOOL)secondary {
    id value = secondary ? state[@"secondary_used_percent"] : state[@"primary_used_percent"];
    if (![value respondsToSelector:@selector(doubleValue)] && secondary) {
        value = state[@"primary_used_percent"];
    }
    if ([value respondsToSelector:@selector(doubleValue)]) {
        return MAX(0.0, MIN(100.0, [value doubleValue]));
    }
    return NAN;
}

- (NSNumber *)resetSecondsForState:(NSDictionary *)state secondary:(BOOL)secondary {
    id value = secondary ? state[@"secondary_resets_at"] : state[@"primary_resets_at"];
    if (![value respondsToSelector:@selector(doubleValue)] && secondary) {
        value = state[@"primary_resets_at"];
    }
    if ([value respondsToSelector:@selector(doubleValue)]) {
        return @([value doubleValue]);
    }
    return nil;
}

- (NSString *)clockTextForSeconds:(NSNumber *)seconds {
    if (seconds == nil) {
        return nil;
    }
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:seconds.doubleValue];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterNoStyle;
    formatter.timeStyle = NSDateFormatterShortStyle;
    return [formatter stringFromDate:date];
}

- (NSString *)countdownTextForSeconds:(NSNumber *)seconds {
    if (seconds == nil) {
        return nil;
    }
    NSInteger remaining = MAX(0, (NSInteger)llround(seconds.doubleValue - [NSDate date].timeIntervalSince1970));
    NSInteger hours = remaining / 3600;
    NSInteger minutes = (remaining % 3600) / 60;
    NSInteger secs = remaining % 60;
    return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)hours, (long)minutes, (long)secs];
}

#pragma mark - Menu

// NSMenuDelegate: AppKit calls this right before the attached menu is shown.
// Rebuild the items of the SAME menu instance so the content is always fresh;
// reassigning statusItem.menu here would cancel the in-flight open.
- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    [self buildMenuItems:menu];
}

- (void)buildMenuItems:(NSMenu *)menu {
    // The provider sections render live API data. If one ever throws, show the
    // error but never lose the control items below — Settings and Quit must
    // stay reachable no matter what the data looks like.
    @try {
        [self addClaudeSectionToMenu:menu];
        [menu addItem:[NSMenuItem separatorItem]];
        [self addCodexSectionToMenu:menu];
    } @catch (NSException *exception) {
        [self addFooterText:[NSString stringWithFormat:@"⚠ Menu error: %@", exception.reason ?: exception.name]
                     toMenu:menu];
    }

    if (self.launchAtLoginError.length > 0) {
        [menu addItem:[NSMenuItem separatorItem]];
        [self addDisabledItem:[NSString stringWithFormat:@"Login item: %@", self.launchAtLoginError] toMenu:menu];
    }

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *settingsItem = [[NSMenuItem alloc] initWithTitle:@"Settings" action:nil keyEquivalent:@""];
    settingsItem.image = [self symbol:@"gearshape"];
    NSMenu *settingsMenu = [[NSMenu alloc] initWithTitle:@"Settings"];
    [self addSettingsToMenu:settingsMenu];
    settingsItem.submenu = settingsMenu;
    [menu addItem:settingsItem];

    [self addActionsToMenu:menu];
}

- (void)addClaudeSectionToMenu:(NSMenu *)menu {
    NSDictionary *state = self.claudeState;
    BOOL secondary = [self claudeUsesSecondary];

    [self addHeaderRowWithIcon:self.claudeIcon
                         title:@"Claude Code"
                      trailing:[self planValueForState:state]
                        toMenu:menu];

    [self addUsageRowWithLabel:@"5h"
                          used:[self usedPercentForState:state secondary:NO]
                         value:[self usageValueForState:state secondary:NO claude:YES]
                       toMenu:menu];
    [self addUsageRowWithLabel:@"7d"
                          used:[self usedPercentForState:state secondary:YES]
                         value:[self usageValueForState:state secondary:YES claude:YES]
                       toMenu:menu];
    NSArray *scopedLimits = [state[@"scoped_limits"] isKindOfClass:[NSArray class]] ? state[@"scoped_limits"] : @[];
    for (id entry in scopedLimits) {
        if (![entry isKindOfClass:[NSDictionary class]]) { continue; }
        NSDictionary *row = entry;
        NSString *label = [row[@"label"] isKindOfClass:[NSString class]] ? row[@"label"] : nil;
        id used = row[@"used_percent"];
        if (label.length == 0 || ![used respondsToSelector:@selector(doubleValue)]) { continue; }
        [self addUsageRowWithLabel:label
                              used:[used doubleValue]
                             value:[self scopedUsageValueForRow:row]
                            toMenu:menu];
    }
    [self addSparkRowForField:@"c" toMenu:menu];
    if (scopedLimits.count == 0) {
        // Legacy per-model footers; superseded by the scoped bar rows above.
        if ([state[@"weekly_opus_summary"] isKindOfClass:[NSString class]]) {
            [self addFooterText:state[@"weekly_opus_summary"] toMenu:menu];
        }
        if ([state[@"weekly_sonnet_summary"] isKindOfClass:[NSString class]]) {
            [self addFooterText:state[@"weekly_sonnet_summary"] toMenu:menu];
        }
    }
    NSString *claudeTokens = [self tokenLineForStats:self.claudeTokenStats includeCost:YES];
    if (claudeTokens.length > 0) {
        [self addFooterText:claudeTokens toMenu:menu];
    }
    // ?: @"" — a nil element in an @[] literal throws and aborts the menu build.
    [self addFooterText:[self joinSummaries:@[state[@"extra_summary"] ?: @"", state[@"updated_summary"] ?: @""]] toMenu:menu];
    if (![self stateOK:state] && [state[@"error"] isKindOfClass:[NSString class]]) {
        [self addFooterText:[NSString stringWithFormat:@"⚠ %@", state[@"error"]] toMenu:menu];
    }
}

- (void)addCodexSectionToMenu:(NSMenu *)menu {
    NSDictionary *state = self.codexState;

    [self addHeaderRowWithIcon:self.codexIcon
                         title:@"Codex"
                      trailing:[self planValueForState:state]
                        toMenu:menu];

    NSString *primaryLabel = [state[@"primary_window_label"] isKindOfClass:[NSString class]] ? state[@"primary_window_label"] : @"5h";
    NSString *secondaryLabel = [state[@"secondary_window_label"] isKindOfClass:[NSString class]] ? state[@"secondary_window_label"] : @"7d";
    [self addUsageRowWithLabel:primaryLabel
                          used:[self usedPercentForState:state secondary:NO]
                         value:[self usageValueForState:state secondary:NO claude:NO]
                       toMenu:menu];
    // Only render a secondary row when the provider actually reported one
    // (free-tier Codex has just a 30d window; the secondary accessors fall
    // back to primary, which would duplicate the first row here).
    if ([state[@"secondary_used_percent"] respondsToSelector:@selector(doubleValue)]) {
        [self addUsageRowWithLabel:secondaryLabel
                              used:[self usedPercentForState:state secondary:YES]
                             value:[self usageValueForState:state secondary:YES claude:NO]
                           toMenu:menu];
    }
    NSArray *codexScoped = [state[@"scoped_limits"] isKindOfClass:[NSArray class]] ? state[@"scoped_limits"] : @[];
    for (id entry in codexScoped) {
        if (![entry isKindOfClass:[NSDictionary class]]) { continue; }
        NSDictionary *row = entry;
        NSString *label = [row[@"label"] isKindOfClass:[NSString class]] ? row[@"label"] : nil;
        id used = row[@"used_percent"];
        if (label.length == 0 || ![used respondsToSelector:@selector(doubleValue)]) { continue; }
        [self addUsageRowWithLabel:label
                              used:[used doubleValue]
                             value:[self scopedUsageValueForRow:row]
                            toMenu:menu];
    }
    [self addSparkRowForField:@"x" toMenu:menu];
    if ([state[@"monthly_summary"] isKindOfClass:[NSString class]]) {
        [self addFooterText:state[@"monthly_summary"] toMenu:menu];
    }

    NSString *codexTokens = [self tokenLineForStats:self.codexTokenStats includeCost:NO];
    if (codexTokens.length > 0) {
        [self addFooterText:codexTokens toMenu:menu];
    }
    NSString *footer = [self joinSummaries:@[state[@"credits_summary"] ?: @"",
                                             state[@"reset_credits_summary"] ?: @"",
                                             state[@"updated_summary"] ?: @""]];
    [self addFooterText:footer toMenu:menu];
    if (![self stateOK:state] && [state[@"error"] isKindOfClass:[NSString class]]) {
        [self addFooterText:[NSString stringWithFormat:@"⚠ %@", state[@"error"]] toMenu:menu];
    }
}

#pragma mark - Styled info rows

- (void)addHeaderRowWithIcon:(NSImage *)icon title:(NSString *)title trailing:(NSString *)trailing toMenu:(NSMenu *)menu {
    AIMHeaderRow *view = [[AIMHeaderRow alloc] initWithFrame:NSMakeRect(0.0, 0.0, AIMRowWidth, 24.0)];
    view.autoresizingMask = NSViewWidthSizable;
    view.icon = icon;
    view.title = title;
    view.trailing = trailing;
    NSMenuItem *item = [[NSMenuItem alloc] init];
    item.view = view;
    [menu addItem:item];
}

- (void)addUsageRowWithLabel:(NSString *)label used:(double)used value:(NSString *)value toMenu:(NSMenu *)menu {
    AIMUsageRow *view = [[AIMUsageRow alloc] initWithFrame:NSMakeRect(0.0, 0.0, AIMRowWidth, 21.0)];
    view.autoresizingMask = NSViewWidthSizable;
    view.label = label;
    view.usedPercent = used;
    view.valueText = value;
    NSMenuItem *item = [[NSMenuItem alloc] init];
    item.view = view;
    [menu addItem:item];
}

// Adds a 24h history sparkline for one provider once enough samples exist.
- (void)addSparkRowForField:(NSString *)field toMenu:(NSMenu *)menu {
    NSArray<NSDictionary *> *points = [self historyPointsForField:field];
    if (points.count < 3) {
        return;
    }
    AIMSparkRow *view = [[AIMSparkRow alloc] initWithFrame:NSMakeRect(0.0, 0.0, AIMRowWidth, 20.0)];
    view.autoresizingMask = NSViewWidthSizable;
    view.label = @"24h";
    view.points = points;
    NSMenuItem *item = [[NSMenuItem alloc] init];
    item.view = view;
    [menu addItem:item];
}

- (void)addFooterText:(NSString *)text toMenu:(NSMenu *)menu {
    if (text.length == 0) { return; }
    NSMenuItem *item = [[NSMenuItem alloc] init];
    item.enabled = NO;
    NSMutableParagraphStyle *p = [[NSMutableParagraphStyle alloc] init];
    p.firstLineHeadIndent = AIMRowLeftInset;
    p.headIndent = AIMRowLeftInset;
    item.attributedTitle = [[NSAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:10.0 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: NSColor.tertiaryLabelColor,
        NSParagraphStyleAttributeName: p
    }];
    [menu addItem:item];
}

// Short value for a usage bar row: "97% left · 2:00 PM" / "3% used · Jul 4" /
// "idle" when the window has no active reset.
- (NSString *)usageValueForState:(NSDictionary *)state secondary:(BOOL)secondary claude:(BOOL)claude {
    double used = [self usedPercentForState:state secondary:secondary];
    NSString *metric = [self shortMetricTextForUsed:used];
    NSNumber *reset = [self resetSecondsForState:state secondary:secondary];
    NSString *clock = [self clockTextForSeconds:reset];
    if (clock.length == 0) {
        NSString *missing = claude ? [self claudeMissingResetReasonForState:state secondary:secondary] : @"—";
        return [NSString stringWithFormat:@"%@ · %@", metric, missing];
    }
    return [NSString stringWithFormat:@"%@ · %@", metric, clock];
}

// Value text for a scoped per-model row, matching usageValueForState's format.
- (NSString *)scopedUsageValueForRow:(NSDictionary *)row {
    NSString *metric = [self shortMetricTextForUsed:[row[@"used_percent"] doubleValue]];
    NSNumber *reset = [row[@"resets_at"] respondsToSelector:@selector(doubleValue)] ? row[@"resets_at"] : nil;
    NSString *clock = [self clockTextForSeconds:reset];
    if (clock.length == 0) {
        return metric;
    }
    return [NSString stringWithFormat:@"%@ · %@", metric, clock];
}

- (NSString *)shortMetricTextForUsed:(double)used {
    if (isnan(used)) { return @"—"; }
    if ([[self metricMode] isEqualToString:MetricModeUsed]) {
        return [NSString stringWithFormat:@"%.0f%% used", used];
    }
    return [NSString stringWithFormat:@"%.0f%% left", MAX(0.0, MIN(100.0, 100.0 - used))];
}

// The plan name without the "Plan: " prefix, capitalized, for the header pill.
- (NSString *)planValueForState:(NSDictionary *)state {
    NSString *summary = state[@"plan_summary"];
    if (![summary isKindOfClass:[NSString class]] || summary.length == 0) { return nil; }
    NSString *value = [summary hasPrefix:@"Plan: "] ? [summary substringFromIndex:6] : summary;
    return [value uppercaseString];
}

// One compact line: "Resets 2:20 AM (in 2:15:15)" or the idle/unknown reason.
- (NSString *)resetLineForState:(NSDictionary *)state secondary:(BOOL)secondary claude:(BOOL)claude {
    NSNumber *reset = [self resetSecondsForState:state secondary:secondary];
    NSString *clock = [self clockTextForSeconds:reset];
    if (clock.length == 0) {
        NSString *missing = claude ? [self claudeMissingResetReasonForState:state secondary:secondary] : @"unknown";
        return [NSString stringWithFormat:@"Resets: %@", missing];
    }
    NSString *countdown = [self countdownTextForSeconds:reset];
    return [NSString stringWithFormat:@"Resets %@ (in %@)", clock, countdown];
}

// Joins non-empty summary strings with " · " for a single compact line.
- (NSString *)joinSummaries:(NSArray *)summaries {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (id s in summaries) {
        if ([s isKindOfClass:[NSString class]] && [s length] > 0) {
            [parts addObject:s];
        }
    }
    return [parts componentsJoinedByString:@" · "];
}

- (void)addSettingsToMenu:(NSMenu *)menu {
    [self addSubheader:@"Display" toMenu:menu];
    [self addChoiceWithTitle:@"Percentage" action:@selector(usePercentDisplay)
                     checked:[[self displayMode] isEqualToString:DisplayModePercent]
                       image:[self symbol:@"percent"] toMenu:menu];
    [self addChoiceWithTitle:@"Battery" action:@selector(useBatteryDisplay)
                     checked:[[self displayMode] isEqualToString:DisplayModeBattery]
                       image:[self symbol:@"battery.100"] toMenu:menu];
    [self addChoiceWithTitle:@"Show % Left" action:@selector(useLeftMetric)
                     checked:[[self metricMode] isEqualToString:MetricModeLeft]
                       image:[self symbol:@"arrow.down.right.circle"] toMenu:menu];
    [self addChoiceWithTitle:@"Show % Used" action:@selector(useUsedMetric)
                     checked:[[self metricMode] isEqualToString:MetricModeUsed]
                       image:[self symbol:@"arrow.up.right.circle"] toMenu:menu];

    [menu addItem:[NSMenuItem separatorItem]];
    [self addSubheader:@"Menu Bar" toMenu:menu];
    [self addChoiceWithTitle:@"Show Claude" action:@selector(toggleShowClaude)
                     checked:[self boolDefault:ShowClaudeKey] image:self.claudeIcon toMenu:menu];
    [self addChoiceWithTitle:@"Show Codex" action:@selector(toggleShowCodex)
                     checked:[self boolDefault:ShowCodexKey] image:self.codexIcon toMenu:menu];
    [self addChoiceWithTitle:@"Show Reset Time" action:@selector(toggleShowTimeInBar)
                     checked:[self boolDefault:ShowTimeInBarKey] image:[self symbol:@"clock"] toMenu:menu];

    [menu addItem:[NSMenuItem separatorItem]];
    [self addSubheader:@"Tracked Window" toMenu:menu];
    [self addChoiceWithTitle:@"Claude — Session (5h)" action:@selector(useClaudeSession)
                     checked:[[self claudeWindow] isEqualToString:ClaudeWindowSession]
                       image:[self symbol:@"clock.arrow.circlepath"] toMenu:menu];
    [self addChoiceWithTitle:@"Claude — Weekly (7d)" action:@selector(useClaudeWeekly)
                     checked:[[self claudeWindow] isEqualToString:ClaudeWindowWeekly]
                       image:[self symbol:@"calendar"] toMenu:menu];
    [self addChoiceWithTitle:@"Codex — Session (5h)" action:@selector(useCodexDaily)
                     checked:[[self codexWindow] isEqualToString:CodexWindowDaily]
                       image:[self symbol:@"clock.arrow.circlepath"] toMenu:menu];
    [self addChoiceWithTitle:@"Codex — Weekly (7d)" action:@selector(useCodexWeekly)
                     checked:[[self codexWindow] isEqualToString:CodexWindowWeekly]
                       image:[self symbol:@"calendar"] toMenu:menu];

    [menu addItem:[NSMenuItem separatorItem]];
    [self addSubheader:@"Time Format" toMenu:menu];
    [self addChoiceWithTitle:@"Reset Time" action:@selector(useClockTime)
                     checked:[[self timeMode] isEqualToString:TimeModeClock]
                       image:[self symbol:@"clock"] toMenu:menu];
    [self addChoiceWithTitle:@"Countdown" action:@selector(useCountdownTime)
                     checked:[[self timeMode] isEqualToString:TimeModeCountdown]
                       image:[self symbol:@"timer"] toMenu:menu];

    [menu addItem:[NSMenuItem separatorItem]];
    [self addChoiceWithTitle:@"Usage Alerts (80% / 95%)" action:@selector(toggleAlerts)
                     checked:[self boolDefault:AlertsEnabledKey] image:[self symbol:@"bell"] toMenu:menu];
    [self addChoiceWithTitle:@"iPhone Sync (LAN)" action:@selector(toggleSyncServer)
                     checked:[self boolDefault:SyncServerEnabledKey] image:[self symbol:@"iphone"] toMenu:menu];
    [self addRefreshIntervalSubmenuToMenu:menu];
    [self addChoiceWithTitle:@"Launch at Login" action:@selector(toggleLaunchAtLogin)
                     checked:[self launchAtLoginEnabled] image:[self symbol:@"power"] toMenu:menu];
}

- (void)addActionsToMenu:(NSMenu *)menu {
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *dashboards = [[NSMenuItem alloc] initWithTitle:@"Open Dashboard" action:nil keyEquivalent:@""];
    dashboards.image = [self symbol:@"safari"];
    NSMenu *dashMenu = [[NSMenu alloc] initWithTitle:@"Open Dashboard"];
    NSMenuItem *claudeDash = [[NSMenuItem alloc] initWithTitle:@"Claude — claude.ai/settings/usage"
                                                        action:@selector(openDashboard:) keyEquivalent:@""];
    claudeDash.target = self;
    claudeDash.image = self.claudeIcon;
    claudeDash.representedObject = @"https://claude.ai/settings/usage";
    [dashMenu addItem:claudeDash];
    NSMenuItem *codexDash = [[NSMenuItem alloc] initWithTitle:@"Codex — chatgpt.com/codex"
                                                       action:@selector(openDashboard:) keyEquivalent:@""];
    codexDash.target = self;
    codexDash.image = self.codexIcon;
    codexDash.representedObject = @"https://chatgpt.com/codex";
    [dashMenu addItem:codexDash];
    dashboards.submenu = dashMenu;
    [menu addItem:dashboards];

    NSMenuItem *refresh = [[NSMenuItem alloc] initWithTitle:@"Refresh Now" action:@selector(refresh) keyEquivalent:@"r"];
    refresh.target = self;
    refresh.image = [self symbol:@"arrow.clockwise"];
    [menu addItem:refresh];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(quit) keyEquivalent:@"q"];
    quit.target = self;
    quit.image = [self symbol:@"power"];
    [menu addItem:quit];
}

- (void)addHeader:(NSString *)title toMenu:(NSMenu *)menu {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    item.enabled = NO;
    NSDictionary *attrs = @{ NSFontAttributeName: [NSFont boldSystemFontOfSize:[NSFont systemFontSize]] };
    item.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:attrs];
    [menu addItem:item];
}

- (void)addChoiceWithTitle:(NSString *)title action:(SEL)action checked:(BOOL)checked toMenu:(NSMenu *)menu {
    [self addChoiceWithTitle:title action:action checked:checked image:nil toMenu:menu];
}

- (void)addChoiceWithTitle:(NSString *)title action:(SEL)action checked:(BOOL)checked image:(NSImage *)image toMenu:(NSMenu *)menu {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    item.state = checked ? NSControlStateValueOn : NSControlStateValueOff;
    item.image = image;
    [menu addItem:item];
}

// A small uppercase section label inside the Settings submenu.
- (void)addSubheader:(NSString *)title toMenu:(NSMenu *)menu {
    NSMenuItem *item = [[NSMenuItem alloc] init];
    item.enabled = NO;
    item.attributedTitle = [[NSAttributedString alloc] initWithString:[title uppercaseString] attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:10.0 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: NSColor.tertiaryLabelColor,
        NSKernAttributeName: @0.5
    }];
    [menu addItem:item];
}

// A template SF Symbol image for menu items (nil on older macOS).
- (NSImage *)symbol:(NSString *)name {
    if (@available(macOS 11.0, *)) {
        NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
        image.template = YES;
        return image;
    }
    return nil;
}

- (void)addRefreshIntervalSubmenuToMenu:(NSMenu *)menu {
    NSTimeInterval current = [self refreshIntervalSeconds];
    NSMenuItem *root = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Refresh Every: %@",
                                                          [self refreshIntervalLabelForSeconds:current]]
                                                  action:nil keyEquivalent:@""];
    root.image = [self symbol:@"arrow.clockwise"];
    NSMenu *submenu = [[NSMenu alloc] initWithTitle:@"Refresh Every"];
    for (NSNumber *interval in @[@30.0, @60.0, @180.0, @300.0]) {
        NSTimeInterval seconds = interval.doubleValue;
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[self refreshIntervalLabelForSeconds:seconds]
                                                      action:@selector(useRefreshInterval:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = interval;
        item.state = fabs(seconds - current) < 0.5 ? NSControlStateValueOn : NSControlStateValueOff;
        [submenu addItem:item];
    }
    root.submenu = submenu;
    [menu addItem:root];
}

- (void)addDisabledItem:(NSString *)title toMenu:(NSMenu *)menu {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title ?: @"" action:nil keyEquivalent:@""];
    item.enabled = NO;
    [menu addItem:item];
}

#pragma mark - Menu detail text

- (NSString *)claudeDetailUsageTextForState:(NSDictionary *)state {
    double used = [self usedPercentForState:state secondary:NO];
    if (isnan(used)) {
        return @"Session (5h): unavailable";
    }
    double left = MAX(0.0, MIN(100.0, 100.0 - used));
    return [NSString stringWithFormat:@"Session (5h): %.0f%% left, %.0f%% used", left, used];
}

- (NSString *)codexDetailUsageTextForState:(NSDictionary *)state {
    double used = [self usedPercentForState:state secondary:NO];
    if (isnan(used)) {
        return @"Codex: unavailable";
    }
    double left = MAX(0.0, MIN(100.0, 100.0 - used));
    return [NSString stringWithFormat:@"Codex: %.0f%% left, %.0f%% used", left, used];
}

// The 5h session window only has a reset_at once it's active; distinguish that
// idle case from a genuine unavailable response.
- (NSString *)claudeMissingResetReasonForState:(NSDictionary *)state secondary:(BOOL)secondary {
    BOOL haveUsage = !isnan([self usedPercentForState:state secondary:secondary]);
    if ([self stateOK:state] && haveUsage) {
        return secondary ? @"no active window" : @"no active session";
    }
    return @"unknown";
}

#pragma mark - Defaults accessors

- (BOOL)boolDefault:(NSString *)key {
    return [NSUserDefaults.standardUserDefaults boolForKey:key];
}

- (NSString *)displayMode {
    NSString *mode = [NSUserDefaults.standardUserDefaults stringForKey:DisplayModeKey];
    return mode.length > 0 ? mode : DisplayModePercent;
}

- (NSString *)metricMode {
    NSString *mode = [NSUserDefaults.standardUserDefaults stringForKey:MetricModeKey];
    return mode.length > 0 ? mode : MetricModeLeft;
}

- (NSString *)timeMode {
    NSString *mode = [NSUserDefaults.standardUserDefaults stringForKey:TimeModeKey];
    return mode.length > 0 ? mode : TimeModeClock;
}

- (NSString *)claudeWindow {
    NSString *mode = [NSUserDefaults.standardUserDefaults stringForKey:ClaudeWindowKey];
    return [mode isEqualToString:ClaudeWindowWeekly] ? ClaudeWindowWeekly : ClaudeWindowSession;
}

- (NSString *)codexWindow {
    NSString *mode = [NSUserDefaults.standardUserDefaults stringForKey:CodexWindowKey];
    return [mode isEqualToString:CodexWindowWeekly] ? CodexWindowWeekly : CodexWindowDaily;
}

- (BOOL)claudeUsesSecondary { return [[self claudeWindow] isEqualToString:ClaudeWindowWeekly]; }
- (BOOL)codexUsesSecondary { return [[self codexWindow] isEqualToString:CodexWindowWeekly]; }

- (NSTimeInterval)refreshIntervalSeconds {
    NSTimeInterval seconds = [NSUserDefaults.standardUserDefaults doubleForKey:RefreshIntervalKey];
    for (NSNumber *interval in @[@30.0, @60.0, @180.0, @300.0]) {
        if (fabs(seconds - interval.doubleValue) < 0.5) {
            return interval.doubleValue;
        }
    }
    return DefaultRefreshIntervalSeconds;
}

- (NSString *)refreshIntervalLabelForSeconds:(NSTimeInterval)seconds {
    if (fabs(seconds - 30.0) < 0.5) {
        return @"30 sec";
    }
    return [NSString stringWithFormat:@"%ld min", (long)llround(seconds / 60.0)];
}

#pragma mark - Menu actions

// Settings change while the menu is open; the menu closes on selection and is
// rebuilt fresh on the next click, so we only need to refresh the bar image.
- (void)applyAndRebuild {
    [self updateStatusItem];
}

- (void)usePercentDisplay { [NSUserDefaults.standardUserDefaults setObject:DisplayModePercent forKey:DisplayModeKey]; [self applyAndRebuild]; }
- (void)useBatteryDisplay { [NSUserDefaults.standardUserDefaults setObject:DisplayModeBattery forKey:DisplayModeKey]; [self applyAndRebuild]; }
- (void)useLeftMetric { [NSUserDefaults.standardUserDefaults setObject:MetricModeLeft forKey:MetricModeKey]; [self applyAndRebuild]; }
- (void)useUsedMetric { [NSUserDefaults.standardUserDefaults setObject:MetricModeUsed forKey:MetricModeKey]; [self applyAndRebuild]; }
- (void)useClockTime { [NSUserDefaults.standardUserDefaults setObject:TimeModeClock forKey:TimeModeKey]; [self applyAndRebuild]; }
- (void)useCountdownTime { [NSUserDefaults.standardUserDefaults setObject:TimeModeCountdown forKey:TimeModeKey]; [self applyAndRebuild]; }
- (void)useClaudeSession { [NSUserDefaults.standardUserDefaults setObject:ClaudeWindowSession forKey:ClaudeWindowKey]; [self applyAndRebuild]; }
- (void)useClaudeWeekly { [NSUserDefaults.standardUserDefaults setObject:ClaudeWindowWeekly forKey:ClaudeWindowKey]; [self applyAndRebuild]; }
- (void)useCodexDaily { [NSUserDefaults.standardUserDefaults setObject:CodexWindowDaily forKey:CodexWindowKey]; [self applyAndRebuild]; }
- (void)useCodexWeekly { [NSUserDefaults.standardUserDefaults setObject:CodexWindowWeekly forKey:CodexWindowKey]; [self applyAndRebuild]; }

- (void)toggleShowClaude {
    [NSUserDefaults.standardUserDefaults setBool:![self boolDefault:ShowClaudeKey] forKey:ShowClaudeKey];
    [self applyAndRebuild];
}
- (void)toggleShowCodex {
    [NSUserDefaults.standardUserDefaults setBool:![self boolDefault:ShowCodexKey] forKey:ShowCodexKey];
    [self applyAndRebuild];
}
- (void)toggleShowTimeInBar {
    [NSUserDefaults.standardUserDefaults setBool:![self boolDefault:ShowTimeInBarKey] forKey:ShowTimeInBarKey];
    [self applyAndRebuild];
}

- (void)toggleAlerts {
    BOOL enabled = ![self boolDefault:AlertsEnabledKey];
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:AlertsEnabledKey];
    if (enabled) {
        [self requestNotificationAuthorization];
    }
    [self applyAndRebuild];
}

- (void)openDashboard:(NSMenuItem *)sender {
    NSString *urlString = [sender.representedObject isKindOfClass:[NSString class]] ? sender.representedObject : nil;
    NSURL *url = urlString.length > 0 ? [NSURL URLWithString:urlString] : nil;
    if (url != nil) {
        [NSWorkspace.sharedWorkspace openURL:url];
    }
}

- (void)useRefreshInterval:(NSMenuItem *)sender {
    NSNumber *interval = sender.representedObject;
    if (![interval respondsToSelector:@selector(doubleValue)]) {
        return;
    }
    [NSUserDefaults.standardUserDefaults setDouble:interval.doubleValue forKey:RefreshIntervalKey];
    [self schedulePollTimer];
}

- (void)schedulePollTimer {
    [self.pollTimer invalidate];
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:[self refreshIntervalSeconds]
                                                      target:self selector:@selector(refresh)
                                                    userInfo:nil repeats:YES];
}

#pragma mark - Refresh (both providers concurrently)

- (void)refresh {
    dispatch_queue_t bg = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    // Serial queue: token scans mutate the shared cache and must not overlap.
    static dispatch_queue_t tokenQueue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tokenQueue = dispatch_queue_create("aiusage.tokenscan", DISPATCH_QUEUE_SERIAL);
    });
    dispatch_async(tokenQueue, ^{
        [self refreshTokenStats];
    });
    dispatch_async(bg, ^{
        dispatch_group_t group = dispatch_group_create();
        __block NSDictionary *claude = nil;
        __block NSDictionary *codex = nil;
        dispatch_group_async(group, bg, ^{ claude = [self loadClaudeState]; });
        dispatch_group_async(group, bg, ^{ codex = [self loadCodexState]; });
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.claudeState = claude;
            self.codexState = codex;
            [self updateStatusItem];
            [self recordHistorySample];
            [self evaluateAlerts];
        });
    });
}

#pragma mark - Token usage stats (local session logs)

// Claude Code writes per-message token usage into ~/.claude/projects/**/*.jsonl
// and Codex writes per-turn token_count events into ~/.codex/sessions. We
// aggregate both into per-day buckets with an incremental per-file cache
// (only files whose mtime/size changed are re-parsed), then publish
// today/all-time totals — with an estimated $ cost for Claude based on
// public API pricing (cost is an estimate: subscription usage isn't billed
// per token, and Fable pricing is approximated with Opus rates).

- (NSString *)tokenCachePath {
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
                     stringByAppendingPathComponent:@"AIUsageMenuBar"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"token-cache.json"];
}

- (NSMutableDictionary *)loadedTokenCache {
    if (self.tokenCache != nil) {
        return self.tokenCache;
    }
    NSData *data = [NSData dataWithContentsOfFile:[self tokenCachePath]];
    NSDictionary *saved = data != nil ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] : nil;
    NSMutableDictionary *cache = [saved isKindOfClass:[NSDictionary class]] ? [saved mutableCopy] : [NSMutableDictionary dictionary];
    if (![cache[@"claude"] isKindOfClass:[NSMutableDictionary class]]) { cache[@"claude"] = [NSMutableDictionary dictionary]; }
    if (![cache[@"codex"] isKindOfClass:[NSMutableDictionary class]]) { cache[@"codex"] = [NSMutableDictionary dictionary]; }
    self.tokenCache = cache;
    return cache;
}

- (void)saveTokenCache {
    if (self.tokenCache == nil) { return; }
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.tokenCache options:0 error:nil];
    [data writeToFile:[self tokenCachePath] atomically:YES];
}

// $/MTok pricing by model family: input, output, cache read, cache write.
- (BOOL)pricingForModel:(NSString *)model into:(double[4])rates {
    NSString *m = model.lowercaseString ?: @"";
    if ([m containsString:@"haiku"]) { rates[0] = 1.0; rates[1] = 5.0; rates[2] = 0.10; rates[3] = 1.25; return YES; }
    if ([m containsString:@"sonnet"]) { rates[0] = 3.0; rates[1] = 15.0; rates[2] = 0.30; rates[3] = 3.75; return YES; }
    if ([m containsString:@"opus"] || [m containsString:@"fable"] || [m containsString:@"mythos"]) {
        rates[0] = 15.0; rates[1] = 75.0; rates[2] = 1.50; rates[3] = 18.75; return YES;
    }
    if ([m containsString:@"claude"]) { rates[0] = 3.0; rates[1] = 15.0; rates[2] = 0.30; rates[3] = 3.75; return YES; }
    return NO;
}

// Re-runs the incremental scan for both providers and publishes the stats.
// Runs on a background queue; heavy only on the very first scan.
- (void)refreshTokenStats {
    NSMutableDictionary *cache = [self loadedTokenCache];

    NSISO8601DateFormatter *iso = [[NSISO8601DateFormatter alloc] init];
    iso.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    NSISO8601DateFormatter *isoPlain = [[NSISO8601DateFormatter alloc] init];
    isoPlain.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    NSDateFormatter *dayFormatter = [[NSDateFormatter alloc] init];
    dayFormatter.dateFormat = @"yyyy-MM-dd";

    NSString *claudeRoot = [@"~/.claude/projects" stringByExpandingTildeInPath];
    [self scanProvider:@"claude" root:claudeRoot cache:cache iso:iso isoPlain:isoPlain day:dayFormatter];

    NSString *codexHome = NSProcessInfo.processInfo.environment[@"CODEX_HOME"];
    if (codexHome.length == 0) { codexHome = [@"~/.codex" stringByExpandingTildeInPath]; }
    [self scanProvider:@"codex" root:[codexHome stringByAppendingPathComponent:@"sessions"] cache:cache iso:iso isoPlain:isoPlain day:dayFormatter];

    [self saveTokenCache];

    NSString *today = [dayFormatter stringFromDate:[NSDate date]];
    NSDictionary *claudeStats = [self aggregateTokenStatsForProvider:@"claude" cache:cache today:today];
    NSDictionary *codexStats = [self aggregateTokenStatsForProvider:@"codex" cache:cache today:today];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.claudeTokenStats = claudeStats;
        self.codexTokenStats = codexStats;
    });
}

- (void)scanProvider:(NSString *)provider
                root:(NSString *)root
               cache:(NSMutableDictionary *)cache
                 iso:(NSISO8601DateFormatter *)iso
            isoPlain:(NSISO8601DateFormatter *)isoPlain
                 day:(NSDateFormatter *)dayFormatter {
    NSMutableDictionary *files = cache[provider];
    NSDirectoryEnumerator<NSURL *> *enumerator =
        [NSFileManager.defaultManager enumeratorAtURL:[NSURL fileURLWithPath:root]
                           includingPropertiesForKeys:@[NSURLContentModificationDateKey, NSURLFileSizeKey]
                                              options:0
                                         errorHandler:nil];
    for (NSURL *url in enumerator) {
        if (![url.pathExtension isEqualToString:@"jsonl"]) { continue; }
        NSDate *mtime = nil;
        NSNumber *size = nil;
        [url getResourceValue:&mtime forKey:NSURLContentModificationDateKey error:nil];
        [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];

        NSDictionary *entry = [files[url.path] isKindOfClass:[NSDictionary class]] ? files[url.path] : nil;
        if (entry != nil &&
            fabs([entry[@"mtime"] doubleValue] - mtime.timeIntervalSince1970) < 0.5 &&
            [entry[@"size"] longLongValue] == size.longLongValue) {
            continue; // unchanged
        }

        NSDictionary *days = [provider isEqualToString:@"claude"]
            ? [self claudeDayBucketsForFile:url.path iso:iso isoPlain:isoPlain day:dayFormatter]
            : [self codexDayBucketsForFile:url.path iso:iso isoPlain:isoPlain day:dayFormatter];
        files[url.path] = @{
            @"mtime": @(mtime.timeIntervalSince1970),
            @"size": size ?: @0,
            @"days": days ?: @{}
        };
    }
}

// Parses one Claude transcript into {day: {tok, cost}} buckets, deduping
// streamed duplicates by message id + request id.
- (NSDictionary *)claudeDayBucketsForFile:(NSString *)path
                                      iso:(NSISO8601DateFormatter *)iso
                                 isoPlain:(NSISO8601DateFormatter *)isoPlain
                                      day:(NSDateFormatter *)dayFormatter {
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (content.length == 0) { return @{}; }

    NSMutableDictionary *daysOut = [NSMutableDictionary dictionary];
    NSMutableSet *seen = [NSMutableSet set];
    [content enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        (void)stop;
        if (![line containsString:@"\"usage\""] || ![line containsString:@"\"timestamp\""]) { return; }
        NSDictionary *event = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if (![event isKindOfClass:[NSDictionary class]]) { return; }
        NSDictionary *message = [event[@"message"] isKindOfClass:[NSDictionary class]] ? event[@"message"] : nil;
        NSDictionary *usage = [message[@"usage"] isKindOfClass:[NSDictionary class]] ? message[@"usage"] : nil;
        if (usage == nil) { return; }

        NSString *messageId = [message[@"id"] isKindOfClass:[NSString class]] ? message[@"id"] : nil;
        NSString *requestId = [event[@"requestId"] isKindOfClass:[NSString class]] ? event[@"requestId"] : nil;
        if (messageId != nil || requestId != nil) {
            NSString *key = [NSString stringWithFormat:@"%@|%@", messageId ?: @"", requestId ?: @""];
            if ([seen containsObject:key]) { return; }
            [seen addObject:key];
        }

        NSString *ts = [event[@"timestamp"] isKindOfClass:[NSString class]] ? event[@"timestamp"] : nil;
        NSDate *date = ts != nil ? ([iso dateFromString:ts] ?: [isoPlain dateFromString:ts]) : nil;
        if (date == nil) { return; }

        double input = [usage[@"input_tokens"] doubleValue];
        double output = [usage[@"output_tokens"] doubleValue];
        double cacheWrite = [usage[@"cache_creation_input_tokens"] doubleValue];
        double cacheRead = [usage[@"cache_read_input_tokens"] doubleValue];
        double tokens = input + output + cacheWrite + cacheRead;
        if (tokens <= 0) { return; }

        double cost = 0;
        double rates[4];
        NSString *model = [message[@"model"] isKindOfClass:[NSString class]] ? message[@"model"] : @"";
        if ([self pricingForModel:model into:rates]) {
            cost = (input * rates[0] + output * rates[1] + cacheRead * rates[2] + cacheWrite * rates[3]) / 1e6;
        }

        NSString *dayKey = [dayFormatter stringFromDate:date];
        NSDictionary *bucket = daysOut[dayKey];
        daysOut[dayKey] = @{
            @"tok": @([bucket[@"tok"] doubleValue] + tokens),
            @"cost": @([bucket[@"cost"] doubleValue] + cost)
        };
    }];
    return daysOut;
}

// Parses one Codex session into {day: {tok}} buckets from per-turn
// last_token_usage payloads.
- (NSDictionary *)codexDayBucketsForFile:(NSString *)path
                                     iso:(NSISO8601DateFormatter *)iso
                                isoPlain:(NSISO8601DateFormatter *)isoPlain
                                     day:(NSDateFormatter *)dayFormatter {
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (content.length == 0) { return @{}; }

    NSMutableDictionary *daysOut = [NSMutableDictionary dictionary];
    [content enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        (void)stop;
        if (![line containsString:@"token_count"] || ![line containsString:@"last_token_usage"]) { return; }
        NSDictionary *event = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if (![event isKindOfClass:[NSDictionary class]]) { return; }
        NSDictionary *payload = [event[@"payload"] isKindOfClass:[NSDictionary class]] ? event[@"payload"] : nil;
        NSDictionary *info = [payload[@"info"] isKindOfClass:[NSDictionary class]] ? payload[@"info"] : nil;
        NSDictionary *last = [info[@"last_token_usage"] isKindOfClass:[NSDictionary class]] ? info[@"last_token_usage"] : nil;
        if (last == nil) { return; }

        NSString *ts = [event[@"timestamp"] isKindOfClass:[NSString class]] ? event[@"timestamp"] : nil;
        NSDate *date = ts != nil ? ([iso dateFromString:ts] ?: [isoPlain dateFromString:ts]) : nil;
        if (date == nil) { return; }

        double tokens = [last[@"total_tokens"] doubleValue];
        if (tokens <= 0) {
            tokens = [last[@"input_tokens"] doubleValue] + [last[@"output_tokens"] doubleValue];
        }
        if (tokens <= 0) { return; }

        NSString *dayKey = [dayFormatter stringFromDate:date];
        NSDictionary *bucket = daysOut[dayKey];
        daysOut[dayKey] = @{ @"tok": @([bucket[@"tok"] doubleValue] + tokens) };
    }];
    return daysOut;
}

- (NSDictionary *)aggregateTokenStatsForProvider:(NSString *)provider cache:(NSDictionary *)cache today:(NSString *)today {
    double todayTokens = 0, todayCost = 0, totalTokens = 0, totalCost = 0;
    NSDictionary *files = [cache[provider] isKindOfClass:[NSDictionary class]] ? cache[provider] : @{};
    for (id path in files) {
        NSDictionary *days = [files[path][@"days"] isKindOfClass:[NSDictionary class]] ? files[path][@"days"] : @{};
        for (NSString *dayKey in days) {
            NSDictionary *bucket = days[dayKey];
            double tokens = [bucket[@"tok"] doubleValue];
            double cost = [bucket[@"cost"] doubleValue];
            totalTokens += tokens;
            totalCost += cost;
            if ([dayKey isEqualToString:today]) {
                todayTokens += tokens;
                todayCost += cost;
            }
        }
    }
    if (totalTokens <= 0) { return nil; }
    return @{
        @"today": @(todayTokens),
        @"today_cost": @(todayCost),
        @"total": @(totalTokens),
        @"total_cost": @(totalCost)
    };
}

// "12.4M" style token counts.
- (NSString *)compactCount:(double)value {
    if (value >= 1e9) { return [NSString stringWithFormat:@"%.2fB", value / 1e9]; }
    if (value >= 1e6) { return [NSString stringWithFormat:@"%.1fM", value / 1e6]; }
    if (value >= 1e3) { return [NSString stringWithFormat:@"%.1fK", value / 1e3]; }
    return [NSString stringWithFormat:@"%.0f", value];
}

- (NSString *)compactCost:(double)value {
    if (value >= 1000.0) { return [NSString stringWithFormat:@"~$%.1fK", value / 1000.0]; }
    if (value >= 100.0) { return [NSString stringWithFormat:@"~$%.0f", value]; }
    return [NSString stringWithFormat:@"~$%.2f", value];
}

// One compact menu line: "Tokens: 12.4M today (~$23.10) · 1.2B total (~$2.1K)".
- (NSString *)tokenLineForStats:(NSDictionary *)stats includeCost:(BOOL)includeCost {
    if (stats == nil) { return nil; }
    double today = [stats[@"today"] doubleValue];
    double total = [stats[@"total"] doubleValue];
    NSMutableString *line = [NSMutableString stringWithFormat:@"Tokens: %@ today", [self compactCount:today]];
    if (includeCost && [stats[@"today_cost"] doubleValue] > 0.005) {
        [line appendFormat:@" (%@)", [self compactCost:[stats[@"today_cost"] doubleValue]]];
    }
    [line appendFormat:@" · %@ total", [self compactCount:total]];
    if (includeCost && [stats[@"total_cost"] doubleValue] > 0.005) {
        [line appendFormat:@" (%@)", [self compactCost:[stats[@"total_cost"] doubleValue]]];
    }
    return line;
}

#pragma mark - LAN sync server (iOS companion app)

// Minimal HTTP server: any GET returns the latest provider states as JSON.
// Published over Bonjour as _aiusage._tcp so the iPhone app finds this Mac
// without configuration. Serves usage numbers only — never credentials.
- (void)startSyncServerIfEnabled {
    if (![self boolDefault:SyncServerEnabledKey] || self.syncSource != nil) {
        return;
    }

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return;
    }
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(SyncServerPort);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 8) != 0) {
        close(fd);
        return;
    }

    self.syncListenFD = fd;
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0,
                                                      dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(source, ^{
        [weakSelf serveSyncConnection];
    });
    dispatch_resume(source);
    self.syncSource = source;

    self.syncService = [[NSNetService alloc] initWithDomain:@"" type:SyncServiceType name:@"" port:SyncServerPort];
    [self.syncService publish];
}

- (void)stopSyncServer {
    if (self.syncSource != nil) {
        dispatch_source_cancel(self.syncSource);
        self.syncSource = nil;
    }
    if (self.syncListenFD >= 0) {
        close(self.syncListenFD);
        self.syncListenFD = -1;
    }
    [self.syncService stop];
    self.syncService = nil;
}

- (void)serveSyncConnection {
    int client = accept(self.syncListenFD, NULL, NULL);
    if (client < 0) {
        return;
    }
    // Drain whatever request line arrived; every path gets the same payload.
    char requestBuffer[2048];
    recv(client, requestBuffer, sizeof(requestBuffer), 0);

    __block NSDictionary *claude = nil;
    __block NSDictionary *codex = nil;
    __block NSDictionary *claudeTokens = nil;
    __block NSDictionary *codexTokens = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        claude = self.claudeState;
        codex = self.codexState;
        claudeTokens = self.claudeTokenStats;
        codexTokens = self.codexTokenStats;
    });

    NSDictionary *payload = @{
        @"v": @1,
        @"generated_at": @([NSDate date].timeIntervalSince1970),
        @"claude": claude ?: @{},
        @"codex": codex ?: @{},
        @"tokens": @{
            @"claude": claudeTokens ?: @{},
            @"codex": codexTokens ?: @{}
        },
        // 24h sample history {t, c, x} so the phone can draw usage charts.
        @"history": [NSUserDefaults.standardUserDefaults arrayForKey:HistoryKey] ?: @[]
    };
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil] ?: [NSData data];
    NSString *header = [NSString stringWithFormat:
        @"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",
        (unsigned long)body.length];
    NSMutableData *response = [[header dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [response appendData:body];
    send(client, response.bytes, response.length, 0);
    close(client);
}

- (void)toggleSyncServer {
    BOOL enabled = ![self boolDefault:SyncServerEnabledKey];
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:SyncServerEnabledKey];
    if (enabled) {
        [self startSyncServerIfEnabled];
    } else {
        [self stopSyncServer];
    }
    [self applyAndRebuild];
}

#pragma mark - Usage alerts

- (void)requestNotificationAuthorization {
    // UNUserNotificationCenter requires a real bundle; guard for safety.
    if (NSBundle.mainBundle.bundleIdentifier == nil) {
        return;
    }
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                          completionHandler:^(BOOL granted, NSError *error) {
        (void)granted;
        (void)error;
    }];
}

- (void)evaluateAlerts {
    if (![self boolDefault:AlertsEnabledKey]) {
        return;
    }
    [self evaluateAlertNamed:@"Claude Code"
                       state:self.claudeState
                   secondary:[self claudeUsesSecondary]
                  defaultKey:ClaudeNotifyLevelKey];
    [self evaluateAlertNamed:@"Codex"
                       state:self.codexState
                   secondary:[self codexUsesSecondary]
                  defaultKey:CodexNotifyLevelKey];
}

// Fires once at 80% and once at 95% of the tracked window; re-arms when usage
// drops back below 75% (i.e. after the window resets).
- (void)evaluateAlertNamed:(NSString *)name state:(NSDictionary *)state secondary:(BOOL)secondary defaultKey:(NSString *)key {
    if (![self stateOK:state]) {
        return;
    }
    double used = [self usedPercentForState:state secondary:secondary];
    if (isnan(used)) {
        return;
    }

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSInteger last = [defaults integerForKey:key];
    if (used < 75.0) {
        if (last != 0) {
            [defaults setInteger:0 forKey:key];
        }
        return;
    }

    NSInteger level = used >= 95.0 ? 95 : (used >= 80.0 ? 80 : 0);
    if (level == 0 || level <= last) {
        return;
    }
    [defaults setInteger:level forKey:key];

    NSString *clock = [self clockTextForSeconds:[self resetSecondsForState:state secondary:secondary]];
    NSString *body = clock.length > 0
        ? [NSString stringWithFormat:@"%.0f%% of the window is used. Resets %@.", used, clock]
        : [NSString stringWithFormat:@"%.0f%% of the window is used.", used];
    [self postNotificationWithTitle:[NSString stringWithFormat:@"%@ usage at %ld%%", name, (long)level]
                               body:body];
}

- (void)postNotificationWithTitle:(NSString *)title body:(NSString *)body {
    if (NSBundle.mainBundle.bundleIdentifier == nil) {
        return;
    }
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = title;
    content.body = body;
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:NSUUID.UUID.UUIDString
                                                                          content:content
                                                                          trigger:nil];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request
                                                          withCompletionHandler:^(NSError *error) {
        (void)error;
    }];
}

#pragma mark - Usage history (24h sparkline)

// Appends the current primary-window used% of both providers and prunes
// anything older than the sparkline window.
- (void)recordHistorySample {
    double claudeUsed = [self stateOK:self.claudeState] ? [self usedPercentForState:self.claudeState secondary:NO] : NAN;
    double codexUsed = [self stateOK:self.codexState] ? [self usedPercentForState:self.codexState secondary:NO] : NAN;
    if (isnan(claudeUsed) && isnan(codexUsed)) {
        return;
    }

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSArray *saved = [defaults arrayForKey:HistoryKey] ?: @[];
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSTimeInterval cutoff = now - HistoryWindowSeconds;

    NSMutableArray *history = [NSMutableArray array];
    for (id entry in saved) {
        if ([entry isKindOfClass:[NSDictionary class]] && [entry[@"t"] doubleValue] >= cutoff) {
            [history addObject:entry];
        }
    }
    [history addObject:@{
        @"t": @(now),
        @"c": @(isnan(claudeUsed) ? -1.0 : claudeUsed),
        @"x": @(isnan(codexUsed) ? -1.0 : codexUsed)
    }];
    // Hard cap as a safety net against pathological refresh rates.
    while (history.count > 4000) {
        [history removeObjectAtIndex:0];
    }
    [defaults setObject:history forKey:HistoryKey];
}

// History points for one provider ('c' = Claude, 'x' = Codex) as {t, v} pairs.
- (NSArray<NSDictionary *> *)historyPointsForField:(NSString *)field {
    NSArray *saved = [NSUserDefaults.standardUserDefaults arrayForKey:HistoryKey] ?: @[];
    NSMutableArray<NSDictionary *> *points = [NSMutableArray array];
    for (id entry in saved) {
        if (![entry isKindOfClass:[NSDictionary class]]) { continue; }
        double v = [entry[field] doubleValue];
        if (v < 0.0) { continue; }
        [points addObject:@{ @"t": entry[@"t"] ?: @0, @"v": @(v) }];
    }
    return points;
}

#pragma mark - Claude data source: OAuth usage API

- (NSDictionary *)loadClaudeState {
    if (self.usageBackoffUntil != nil && [self.usageBackoffUntil timeIntervalSinceNow] > 0 &&
        self.claudeLastGoodState != nil) {
        return [self claudeStaleStateFromGood:self.claudeLastGoodState];
    }

    NSString *credsError = nil;
    NSDictionary *creds = [self currentClaudeCredentials:&credsError];
    if (creds == nil) {
        return [self claudeStateForFailure:credsError ?: @"Claude Code credentials not found"];
    }

    NSString *tokenError = nil;
    NSString *accessToken = [self validAccessTokenFromCredentials:creds error:&tokenError];
    if (accessToken.length == 0) {
        return [self claudeStateForFailure:tokenError ?: @"No valid access token"];
    }

    NSInteger status = 0;
    NSString *httpError = nil;
    NSTimeInterval retryAfter = 0;
    NSData *data = [self getURL:ClaudeUsageURL bearer:accessToken statusCode:&status retryAfter:&retryAfter error:&httpError];

    if (status == 401) {
        NSString *refreshError = nil;
        NSString *refreshed = [self refreshAccessTokenWithCredentials:creds error:&refreshError];
        if (refreshed.length > 0) {
            data = [self getURL:ClaudeUsageURL bearer:refreshed statusCode:&status retryAfter:&retryAfter error:&httpError];
            accessToken = refreshed;
        }
    }

    if (status == 429) {
        [self enterUsageBackoffWithRetryAfter:retryAfter];
        return [self claudeStateForFailure:@"Rate limited by Claude usage API"];
    }
    if (data == nil || status != 200) {
        [self enterUsageBackoffWithRetryAfter:0];
        NSString *detail = httpError.length > 0 ? httpError : [NSString stringWithFormat:@"HTTP %ld", (long)status];
        return [self claudeStateForFailure:[NSString stringWithFormat:@"Usage request failed: %@", detail]];
    }

    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) {
        return [self claudeStateForFailure:@"Usage response was not valid JSON"];
    }

    NSString *plan = [self stringFromDictionary:creds keys:@[@"subscriptionType"]];
    NSDictionary *fresh = [self buildClaudeStateFromUsageResponse:json plan:plan timestamp:[NSDate date]];
    if ([self stateOK:fresh]) {
        [self clearUsageBackoff];
        [self storeClaudeLastGoodState:fresh];
        return fresh;
    }
    return [self claudeStateForFailure:fresh[@"error"] ?: @"Usage response was incomplete"];
}

- (NSDictionary *)claudeStateForFailure:(NSString *)message {
    if (self.claudeLastGoodState != nil) {
        return [self claudeStaleStateFromGood:self.claudeLastGoodState];
    }
    return @{
        @"ok": @NO,
        @"updated_summary": @"Updated: unavailable",
        @"source_summary": @"Source: Claude Code usage API",
        @"error": message ?: @"unknown error"
    };
}

- (NSDictionary *)claudeStaleStateFromGood:(NSDictionary *)good {
    NSMutableDictionary *state = [good mutableCopy];
    state[@"updated_summary"] = [self claudeStalenessSummary];
    return state;
}

- (NSString *)claudeStalenessSummary {
    if (self.claudeLastGoodFetchedAt == nil) {
        return @"Updated: unknown";
    }
    NSTimeInterval ago = -[self.claudeLastGoodFetchedAt timeIntervalSinceNow];
    if (ago < 60.0) {
        return @"Updated: just now";
    }
    NSInteger minutes = (NSInteger)(ago / 60.0);
    if (minutes < 60) {
        return [NSString stringWithFormat:@"Updated: %ldm ago", (long)minutes];
    }
    return [NSString stringWithFormat:@"Updated: %ldh ago", (long)(minutes / 60)];
}

- (void)storeClaudeLastGoodState:(NSDictionary *)state {
    self.claudeLastGoodState = state;
    self.claudeLastGoodFetchedAt = [NSDate date];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:state forKey:ClaudeLastGoodStateKey];
    [defaults setDouble:self.claudeLastGoodFetchedAt.timeIntervalSince1970 forKey:ClaudeLastGoodFetchedAtKey];
}

- (void)restoreClaudeLastGoodState {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDictionary *saved = [defaults dictionaryForKey:ClaudeLastGoodStateKey];
    double fetchedAt = [defaults doubleForKey:ClaudeLastGoodFetchedAtKey];
    if (![saved isKindOfClass:[NSDictionary class]] || fetchedAt <= 0) {
        return;
    }
    self.claudeLastGoodState = saved;
    self.claudeLastGoodFetchedAt = [NSDate dateWithTimeIntervalSince1970:fetchedAt];
    self.claudeState = [self claudeStaleStateFromGood:saved];
}

- (void)enterUsageBackoffWithRetryAfter:(NSTimeInterval)retryAfter {
    NSTimeInterval wait;
    if (retryAfter > 0) {
        wait = MIN(retryAfter, UsageBackoffMaxSeconds);
    } else {
        NSTimeInterval next = self.usageBackoffSeconds > 0
            ? self.usageBackoffSeconds * 2.0
            : MAX([self refreshIntervalSeconds], 30.0);
        wait = MIN(next, UsageBackoffMaxSeconds);
    }
    self.usageBackoffSeconds = wait;
    self.usageBackoffUntil = [NSDate dateWithTimeIntervalSinceNow:wait];
}

- (void)clearUsageBackoff {
    self.usageBackoffSeconds = 0;
    self.usageBackoffUntil = nil;
}

- (NSDictionary *)buildClaudeStateFromUsageResponse:(NSDictionary *)response plan:(NSString *)plan timestamp:(NSDate *)timestamp {
    NSDictionary *fiveHour = [response[@"five_hour"] isKindOfClass:[NSDictionary class]] ? response[@"five_hour"] : nil;
    NSDictionary *sevenDay = [response[@"seven_day"] isKindOfClass:[NSDictionary class]] ? response[@"seven_day"] : nil;
    NSDictionary *sevenDayOpus = [response[@"seven_day_opus"] isKindOfClass:[NSDictionary class]] ? response[@"seven_day_opus"] : nil;

    NSNumber *primaryUsed = [self utilizationPercentFromWindow:fiveHour];
    NSNumber *primaryReset = [self resetEpochFromWindow:fiveHour];
    NSNumber *secondaryUsed = [self utilizationPercentFromWindow:sevenDay];
    NSNumber *secondaryReset = [self resetEpochFromWindow:sevenDay];

    if (primaryUsed == nil && secondaryUsed == nil) {
        return @{ @"ok": @NO, @"error": @"Usage response had no rate-limit windows" };
    }

    NSMutableDictionary *state = [@{
        @"ok": @YES,
        @"updated_summary": [self updatedSummaryForDate:timestamp],
        @"source_summary": @"Source: Claude Code usage API"
    } mutableCopy];

    if (primaryUsed != nil) { state[@"primary_used_percent"] = primaryUsed; }
    if (primaryReset != nil) { state[@"primary_resets_at"] = primaryReset; }
    if (secondaryUsed != nil) { state[@"secondary_used_percent"] = secondaryUsed; }
    if (secondaryReset != nil) { state[@"secondary_resets_at"] = secondaryReset; }

    NSString *weekly = [self windowSummaryWithLabel:@"Weekly (7d)" used:secondaryUsed reset:secondaryReset includeDate:YES];
    if (weekly.length > 0) { state[@"weekly_summary"] = weekly; }

    NSNumber *opusUsed = [self utilizationPercentFromWindow:sevenDayOpus];
    NSNumber *opusReset = [self resetEpochFromWindow:sevenDayOpus];
    if (opusUsed != nil) {
        NSString *opus = [self windowSummaryWithLabel:@"Weekly (Opus)" used:opusUsed reset:opusReset includeDate:YES];
        if (opus.length > 0) { state[@"weekly_opus_summary"] = opus; }
    }

    NSDictionary *sevenDaySonnet = [response[@"seven_day_sonnet"] isKindOfClass:[NSDictionary class]] ? response[@"seven_day_sonnet"] : nil;
    NSNumber *sonnetUsed = [self utilizationPercentFromWindow:sevenDaySonnet];
    if (sonnetUsed != nil && sonnetUsed.doubleValue > 0.0) {
        NSString *sonnet = [self windowSummaryWithLabel:@"Weekly (Sonnet)"
                                                   used:sonnetUsed
                                                  reset:[self resetEpochFromWindow:sevenDaySonnet]
                                            includeDate:YES];
        if (sonnet.length > 0) { state[@"weekly_sonnet_summary"] = sonnet; }
    }

    NSArray *scoped = [self scopedWeeklyLimitsFromResponse:response];
    if (scoped.count > 0) { state[@"scoped_limits"] = scoped; }

    NSString *extra = [self extraUsageSummaryFromResponse:response];
    if (extra.length > 0) {
        state[@"extra_summary"] = extra;
    }

    if (plan.length > 0) {
        state[@"plan_summary"] = [NSString stringWithFormat:@"Plan: %@", [plan capitalizedString]];
    }
    return state;
}

// Per-model weekly limits from the newer `limits` array — e.g. the "Fable"
// weekly cap shown on claude.ai. The legacy seven_day_opus/seven_day_sonnet
// windows are null on accounts that have these, so this is their replacement:
// entries with kind "weekly_scoped" and a scope.model.display_name.
- (NSArray<NSDictionary *> *)scopedWeeklyLimitsFromResponse:(NSDictionary *)response {
    NSArray *limits = [response[@"limits"] isKindOfClass:[NSArray class]] ? response[@"limits"] : @[];
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    for (id entry in limits) {
        if (![entry isKindOfClass:[NSDictionary class]]) { continue; }
        NSDictionary *limit = entry;
        if (![limit[@"kind"] isKindOfClass:[NSString class]] || ![limit[@"kind"] isEqualToString:@"weekly_scoped"]) { continue; }
        NSDictionary *scope = [limit[@"scope"] isKindOfClass:[NSDictionary class]] ? limit[@"scope"] : nil;
        NSDictionary *model = [scope[@"model"] isKindOfClass:[NSDictionary class]] ? scope[@"model"] : nil;
        NSString *name = [self stringFromDictionary:model keys:@[@"display_name"]];
        NSNumber *percent = [self numberFromDictionary:limit keys:@[@"percent"]];
        if (name.length == 0 || percent == nil) { continue; }
        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        row[@"label"] = name;
        row[@"used_percent"] = @(MAX(0.0, MIN(100.0, percent.doubleValue)));
        NSNumber *reset = [self resetEpochFromWindow:limit];
        if (reset != nil) { row[@"resets_at"] = reset; }
        [rows addObject:row];
    }
    return rows;
}

// Pay-as-you-go extra usage: "Extra usage: $387.46 of $2,000 (19%)".
// used_credits/monthly_limit are integers scaled by decimal_places.
- (NSString *)extraUsageSummaryFromResponse:(NSDictionary *)response {
    NSDictionary *extra = [response[@"extra_usage"] isKindOfClass:[NSDictionary class]] ? response[@"extra_usage"] : nil;
    if (extra == nil) {
        return nil;
    }
    NSNumber *enabled = [extra[@"is_enabled"] respondsToSelector:@selector(boolValue)] ? extra[@"is_enabled"] : nil;
    if (enabled != nil && !enabled.boolValue) {
        return nil;
    }
    NSNumber *usedCredits = [self numberFromDictionary:extra keys:@[@"used_credits"]];
    NSNumber *monthlyLimit = [self numberFromDictionary:extra keys:@[@"monthly_limit"]];
    if (usedCredits == nil || monthlyLimit == nil || monthlyLimit.doubleValue <= 0.0) {
        return nil;
    }
    NSNumber *decimalPlaces = [self numberFromDictionary:extra keys:@[@"decimal_places"]];
    double divisor = pow(10.0, decimalPlaces != nil ? decimalPlaces.doubleValue : 2.0);
    double used = usedCredits.doubleValue / divisor;
    double limit = monthlyLimit.doubleValue / divisor;
    double percent = MAX(0.0, MIN(100.0, used / limit * 100.0));
    return [NSString stringWithFormat:@"Extra: $%.2f of $%.0f (%.0f%%)", used, limit, percent];
}

- (NSNumber *)utilizationPercentFromWindow:(NSDictionary *)window {
    if (![window isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    id value = window[@"utilization"];
    if (![value respondsToSelector:@selector(doubleValue)]) {
        return nil;
    }
    return @(MAX(0.0, MIN(100.0, [value doubleValue])));
}

- (NSNumber *)resetEpochFromWindow:(NSDictionary *)window {
    if (![window isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    id value = window[@"resets_at"];
    if ([value isKindOfClass:[NSString class]]) {
        NSDate *date = [self dateFromISOString:value];
        return date != nil ? @(date.timeIntervalSince1970) : nil;
    }
    if ([value respondsToSelector:@selector(doubleValue)]) {
        double number = [value doubleValue];
        if (number > 1e12) { number /= 1000.0; }
        return @(number);
    }
    return nil;
}

- (NSString *)windowSummaryWithLabel:(NSString *)label used:(NSNumber *)used reset:(NSNumber *)reset includeDate:(BOOL)includeDate {
    if (used == nil) {
        return nil;
    }
    double usedValue = MAX(0.0, MIN(100.0, used.doubleValue));
    NSString *usedText;
    if ([[self metricMode] isEqualToString:MetricModeUsed]) {
        usedText = [NSString stringWithFormat:@"%.0f%% used", usedValue];
    } else {
        double leftValue = MAX(0.0, MIN(100.0, 100.0 - usedValue));
        usedText = [NSString stringWithFormat:@"%.0f%% left, %.0f%% used", leftValue, usedValue];
    }
    if (reset == nil) {
        return [NSString stringWithFormat:@"%@: %@", label, usedText];
    }
    return [NSString stringWithFormat:@"%@: %@, resets %@", label, usedText, [self resetLabelForSeconds:reset includeDate:includeDate]];
}

#pragma mark - Claude credentials + OAuth

// Resolves credentials without prompting: freshest of the in-memory cache, the
// CLI's ~/.claude/.credentials.json, and our own cache file. The keychain is
// only consulted when none of those exist, and a granted read is persisted to
// our cache file so the prompt can never recur on later launches.
- (NSDictionary *)currentClaudeCredentials:(NSString **)error {
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    if (self.claudeCredsCache != nil) { [candidates addObject:self.claudeCredsCache]; }
    NSDictionary *cliFile = [self readCredentialsFileAtPath:[self claudeCLICredentialsPath]];
    if (cliFile != nil) { [candidates addObject:cliFile]; }
    NSDictionary *cached = [self readCredentialsFileAtPath:[self appCredentialsCachePath]];
    if (cached != nil) { [candidates addObject:cached]; }

    NSDictionary *best = nil;
    double bestExpiry = -1.0;
    for (NSDictionary *candidate in candidates) {
        double expiry = [self numberFromDictionary:candidate keys:@[@"expiresAt"]].doubleValue;
        if (best == nil || expiry > bestExpiry) {
            best = candidate;
            bestExpiry = expiry;
        }
    }
    if (best != nil) {
        self.claudeCredsCache = best;
        return best;
    }

    NSDictionary *keychain = [self readKeychainCredentials:error];
    if (keychain != nil) {
        [self persistCredentials:keychain];
    }
    return keychain;
}

- (NSString *)claudeCLICredentialsPath {
    return [NSHomeDirectory() stringByAppendingPathComponent:@".claude/.credentials.json"];
}

- (NSString *)appCredentialsCachePath {
    NSString *appSupport = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [[appSupport stringByAppendingPathComponent:@"AI Usage Menu Bar"]
            stringByAppendingPathComponent:@"claude-oauth.json"];
}

- (NSDictionary *)readCredentialsFileAtPath:(NSString *)path {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data == nil) { return nil; }
    return [self oauthDictionaryFromJSONData:data];
}

- (NSDictionary *)oauthDictionaryFromJSONData:(NSData *)data {
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSDictionary *root = [json isKindOfClass:[NSDictionary class]] ? json : nil;
    NSDictionary *oauth = [root[@"claudeAiOauth"] isKindOfClass:[NSDictionary class]] ? root[@"claudeAiOauth"] : root;
    if (![oauth isKindOfClass:[NSDictionary class]]) { return nil; }
    if ([self stringFromDictionary:oauth keys:@[@"accessToken"]].length == 0 &&
        [self stringFromDictionary:oauth keys:@[@"refreshToken"]].length == 0) {
        return nil;
    }
    return oauth;
}

// Stores credentials in memory and mirrors them to our own 0600 cache file so
// later launches never need the keychain. Never writes to the CLI's file or
// keychain item — the CLI owns those, and updating another app's keychain item
// both prompts and risks clobbering tokens the CLI refreshed in the meantime.
- (void)persistCredentials:(NSDictionary *)oauth {
    self.claudeCredsCache = oauth;
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"claudeAiOauth": oauth} options:0 error:nil];
    if (data == nil) { return; }
    NSString *path = [self appCredentialsCachePath];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:path.stringByDeletingLastPathComponent
  withIntermediateDirectories:YES
                   attributes:@{ NSFilePosixPermissions: @0700 }
                        error:nil];
    [data writeToFile:path options:NSDataWritingAtomic error:nil];
    [fm setAttributes:@{ NSFilePosixPermissions: @0600 } ofItemAtPath:path error:nil];
}

- (NSDictionary *)readKeychainCredentials:(NSString **)error {
    if (self.keychainDenyUntil != nil && [self.keychainDenyUntil timeIntervalSinceNow] > 0) {
        if (error) { *error = @"Keychain access denied (will retry later)"; }
        return nil;
    }
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: KeychainService,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || result == NULL) {
        if (error) {
            if (status == errSecItemNotFound) {
                *error = @"Not signed in to Claude Code (no keychain item)";
            } else if (status == errSecUserCanceled || status == errSecAuthFailed) {
                *error = @"Keychain access denied";
            } else {
                *error = [NSString stringWithFormat:@"Keychain error %d", (int)status];
            }
        }
        if (status == errSecUserCanceled || status == errSecAuthFailed) {
            // Denied prompts must not recur every poll tick.
            self.keychainDenyUntil = [NSDate dateWithTimeIntervalSinceNow:6.0 * 3600.0];
        }
        return nil;
    }
    NSData *data = (__bridge_transfer NSData *)result;
    NSDictionary *oauth = [self oauthDictionaryFromJSONData:data];
    if (oauth == nil) {
        if (error) { *error = @"Keychain credentials were not valid JSON"; }
        return nil;
    }
    return oauth;
}

- (NSString *)validAccessTokenFromCredentials:(NSDictionary *)creds error:(NSString **)error {
    NSString *accessToken = [self stringFromDictionary:creds keys:@[@"accessToken"]];
    NSNumber *expiresAt = [self numberFromDictionary:creds keys:@[@"expiresAt"]];

    BOOL expired = NO;
    if (expiresAt != nil) {
        double expiresSeconds = expiresAt.doubleValue / 1000.0;
        expired = ([NSDate date].timeIntervalSince1970 >= (expiresSeconds - 60.0));
    }
    if (accessToken.length > 0 && !expired) {
        return accessToken;
    }

    NSString *refreshError = nil;
    NSString *refreshed = [self refreshAccessTokenWithCredentials:creds error:&refreshError];
    if (refreshed.length > 0) {
        return refreshed;
    }
    if (accessToken.length > 0) {
        return accessToken;
    }
    if (error) { *error = refreshError ?: @"Could not obtain access token"; }
    return nil;
}

- (NSString *)refreshAccessTokenWithCredentials:(NSDictionary *)creds error:(NSString **)error {
    if (self.refreshBackoffUntil != nil && [self.refreshBackoffUntil timeIntervalSinceNow] > 0) {
        if (error) { *error = @"Token refresh backing off after a recent failure"; }
        return nil;
    }
    NSString *refreshToken = [self stringFromDictionary:creds keys:@[@"refreshToken"]];
    if (refreshToken.length == 0) {
        if (error) { *error = @"No refresh token available"; }
        return nil;
    }

    NSMutableArray<NSString *> *scopes = [NSMutableArray array];
    if ([creds[@"scopes"] isKindOfClass:[NSArray class]]) {
        for (id scope in creds[@"scopes"]) {
            if ([scope isKindOfClass:[NSString class]]) { [scopes addObject:scope]; }
        }
    }

    NSDictionary *body = @{
        @"grant_type": @"refresh_token",
        @"refresh_token": refreshToken,
        @"client_id": OAuthClientID,
        @"scope": [scopes componentsJoinedByString:@" "]
    };

    NSInteger status = 0;
    NSString *httpError = nil;
    NSData *responseData = [self postURL:OAuthTokenURL jsonBody:body statusCode:&status error:&httpError];
    if (responseData == nil || status != 200) {
        self.refreshBackoffUntil = [NSDate dateWithTimeIntervalSinceNow:300.0];
        if (error) {
            *error = httpError.length > 0 ? httpError : [NSString stringWithFormat:@"Token refresh HTTP %ld", (long)status];
        }
        return nil;
    }

    id json = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil];
    NSDictionary *root = [json isKindOfClass:[NSDictionary class]] ? json : nil;
    NSString *newAccess = [self stringFromDictionary:root keys:@[@"access_token"]];
    if (newAccess.length == 0) {
        self.refreshBackoffUntil = [NSDate dateWithTimeIntervalSinceNow:300.0];
        if (error) { *error = @"Token refresh response had no access_token"; }
        return nil;
    }

    self.refreshBackoffUntil = nil;
    NSString *newRefresh = [self stringFromDictionary:root keys:@[@"refresh_token"]] ?: refreshToken;
    NSNumber *expiresIn = [self numberFromDictionary:root keys:@[@"expires_in"]];
    double expiresAtMs = expiresIn != nil
        ? ([NSDate date].timeIntervalSince1970 + expiresIn.doubleValue) * 1000.0
        : ([NSDate date].timeIntervalSince1970 + 3600.0) * 1000.0;
    NSMutableDictionary *oauth = [creds mutableCopy];
    oauth[@"accessToken"] = newAccess;
    oauth[@"refreshToken"] = newRefresh;
    oauth[@"expiresAt"] = @((long long)llround(expiresAtMs));
    [self persistCredentials:oauth];
    return newAccess;
}

#pragma mark - HTTP helpers (synchronous, run on a background queue)

- (NSData *)getURL:(NSString *)urlString bearer:(NSString *)bearer statusCode:(NSInteger *)statusCode retryAfter:(NSTimeInterval *)retryAfter error:(NSString **)error {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = 10.0;
    [request setValue:[NSString stringWithFormat:@"Bearer %@", bearer] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:OAuthBetaHeader forHTTPHeaderField:@"anthropic-beta"];
    return [self sendRequest:request statusCode:statusCode retryAfter:retryAfter error:error];
}

- (NSData *)postURL:(NSString *)urlString jsonBody:(NSDictionary *)body statusCode:(NSInteger *)statusCode error:(NSString **)error {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 15.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:OAuthBetaHeader forHTTPHeaderField:@"anthropic-beta"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    return [self sendRequest:request statusCode:statusCode retryAfter:NULL error:error];
}

- (NSData *)sendRequest:(NSURLRequest *)request statusCode:(NSInteger *)statusCode retryAfter:(NSTimeInterval *)retryAfter error:(NSString **)error {
    __block NSData *resultData = nil;
    __block NSInteger resultStatus = 0;
    __block NSTimeInterval resultRetryAfter = 0;
    __block NSString *resultError = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                completionHandler:^(NSData *data, NSURLResponse *response, NSError *taskError) {
        if (taskError != nil) {
            resultError = taskError.localizedDescription;
        } else {
            resultData = data;
            if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
                resultStatus = http.statusCode;
                id rawRetryAfter = http.allHeaderFields[@"Retry-After"];
                if ([rawRetryAfter respondsToSelector:@selector(doubleValue)]) {
                    resultRetryAfter = [rawRetryAfter doubleValue];
                }
            }
        }
        dispatch_semaphore_signal(done);
    }];
    [task resume];

    long waited = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)));
    if (waited != 0) {
        [task cancel];
        if (error) { *error = @"Request timed out"; }
        return nil;
    }
    if (statusCode) { *statusCode = resultStatus; }
    if (retryAfter) { *retryAfter = resultRetryAfter; }
    if (error && resultError != nil) { *error = resultError; }
    return resultData;
}

#pragma mark - Codex data source: app-server + JSONL fallback

- (NSDictionary *)loadCodexState {
    NSDictionary *liveState = [self loadCodexStateFromAppServer];
    if ([self stateOK:liveState]) {
        return liveState;
    }

    NSDictionary *offlineState = [self loadCodexStateFromJSONL];
    if ([self stateOK:offlineState]) {
        NSMutableDictionary *state = [offlineState mutableCopy];
        NSString *liveError = liveState[@"error"];
        if ([liveError isKindOfClass:[NSString class]] && liveError.length > 0) {
            state[@"live_error"] = liveError;
        }
        return state;
    }

    NSString *liveError = [liveState[@"error"] isKindOfClass:[NSString class]] ? liveState[@"error"] : @"Codex app-server unavailable";
    NSString *offlineError = [offlineState[@"error"] isKindOfClass:[NSString class]] ? offlineState[@"error"] : @"No offline usage event found";
    return @{
        @"ok": @NO,
        @"updated_summary": @"Updated: unavailable",
        @"source_summary": @"Source: unavailable",
        @"error": [NSString stringWithFormat:@"Live: %@; offline: %@", liveError, offlineError]
    };
}

- (NSDictionary *)loadCodexStateFromAppServer {
    NSString *codexPath = [self codexCLIPath];
    if (codexPath.length == 0) {
        return @{@"ok": @NO, @"error": @"Codex CLI not found"};
    }

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:codexPath];
    task.arguments = @[@"app-server", @"--stdio"];

    NSPipe *stdinPipe = [NSPipe pipe];
    NSPipe *stdoutPipe = [NSPipe pipe];
    NSPipe *stderrPipe = [NSPipe pipe];
    task.standardInput = stdinPipe;
    task.standardOutput = stdoutPipe;
    task.standardError = stderrPipe;

    NSMutableData *outputData = [NSMutableData data];
    NSMutableData *errorData = [NSMutableData data];
    dispatch_semaphore_t responseReady = dispatch_semaphore_create(0);

    stdoutPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *chunk = [handle availableData];
        if (chunk.length == 0) { return; }
        @synchronized (outputData) {
            [outputData appendData:chunk];
            if ([self jsonRPCResponseWithId:@"codex-usage-menu-bar" fromData:outputData] != nil) {
                dispatch_semaphore_signal(responseReady);
            }
        }
    };
    stderrPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *chunk = [handle availableData];
        if (chunk.length == 0) { return; }
        @synchronized (errorData) { [errorData appendData:chunk]; }
    };

    @try {
        [task launch];
        NSDictionary *initialize = @{
            @"id": @"codex-usage-menu-bar-init",
            @"method": @"initialize",
            @"params": @{
                @"clientInfo": @{
                    @"name": @"ai-usage-menu-bar",
                    @"version": NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"0.1.0"
                },
                @"capabilities": @{ @"experimentalApi": @YES }
            }
        };
        NSDictionary *request = @{
            @"id": @"codex-usage-menu-bar",
            @"method": @"account/rateLimits/read",
            @"params": [NSNull null]
        };
        NSData *initializeData = [NSJSONSerialization dataWithJSONObject:initialize options:0 error:nil];
        NSData *requestData = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
        if (initializeData != nil) {
            [[stdinPipe fileHandleForWriting] writeData:initializeData];
            [[stdinPipe fileHandleForWriting] writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
        }
        if (requestData != nil) {
            [[stdinPipe fileHandleForWriting] writeData:requestData];
            [[stdinPipe fileHandleForWriting] writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
        }
    } @catch (NSException *exception) {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil;
        stderrPipe.fileHandleForReading.readabilityHandler = nil;
        return @{
            @"ok": @NO,
            @"error": [NSString stringWithFormat:@"Could not start Codex app-server: %@", exception.reason ?: @"unknown"]
        };
    }

    long waitResult = dispatch_semaphore_wait(responseReady, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)));
    stdoutPipe.fileHandleForReading.readabilityHandler = nil;
    stderrPipe.fileHandleForReading.readabilityHandler = nil;

    [[stdinPipe fileHandleForWriting] closeFile];
    if (task.isRunning) {
        [task terminate];
        [task waitUntilExit];
    }

    if (waitResult != 0) {
        return @{@"ok": @NO, @"error": @"Codex app-server request timed out"};
    }

    NSData *data = nil;
    @synchronized (outputData) { data = [outputData copy]; }
    NSDictionary *response = [self jsonRPCResponseWithId:@"codex-usage-menu-bar" fromData:data];
    NSDictionary *result = [response[@"result"] isKindOfClass:[NSDictionary class]] ? response[@"result"] : nil;
    if (result != nil) {
        NSDictionary *state = [self buildCodexStateFromRateLimitsResult:result sourceText:@"Codex app-server" timestamp:[NSDate date]];
        if (state != nil) { return state; }
    }

    NSData *capturedErrorData = nil;
    @synchronized (errorData) { capturedErrorData = [errorData copy]; }
    NSString *stderrText = [[NSString alloc] initWithData:capturedErrorData encoding:NSUTF8StringEncoding];
    NSString *message = stderrText.length > 0
        ? [stderrText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        : @"Codex app-server returned invalid JSON";
    return @{ @"ok": @NO, @"error": message };
}

- (NSString *)codexCLIPath {
    NSString *override = NSProcessInfo.processInfo.environment[@"CODEX_CLI"];
    if (override.length > 0) {
        return override;
    }
    NSArray<NSString *> *candidates = @[
        @"/Applications/Codex.app/Contents/Resources/codex",
        [@"~/.local/bin/codex" stringByExpandingTildeInPath],
        @"/opt/homebrew/bin/codex",
        @"/usr/local/bin/codex"
    ];
    for (NSString *path in candidates) {
        if ([NSFileManager.defaultManager isExecutableFileAtPath:path]) {
            return path;
        }
    }
    return nil;
}

- (NSDictionary *)jsonRPCResponseWithId:(NSString *)requestId fromData:(NSData *)data {
    if (data.length == 0) {
        return nil;
    }
    id whole = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([whole isKindOfClass:[NSDictionary class]] && [whole[@"id"] isEqual:requestId]) {
        return whole;
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (line.length == 0) { continue; }
        NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
        id object = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:nil];
        if ([object isKindOfClass:[NSDictionary class]] && [object[@"id"] isEqual:requestId]) {
            return object;
        }
    }
    return nil;
}

- (NSDictionary *)loadCodexStateFromJSONL {
    NSDictionary *event = [self latestOfflineUsageEvent];
    if (event == nil) {
        return @{
            @"ok": @NO,
            @"updated_summary": @"Updated: no local token-count event found",
            @"error": @"No Codex usage event found under ~/.codex/sessions"
        };
    }
    NSDictionary *rateLimits = [event[@"rate_limits"] isKindOfClass:[NSDictionary class]] ? event[@"rate_limits"] : nil;
    if (rateLimits == nil) {
        return @{@"ok": @NO, @"error": @"Offline usage event has no rate limit snapshot"};
    }
    NSDate *timestamp = [self dateFromISOString:event[@"timestamp"]];
    return [self buildCodexStateFromLegacySnapshot:rateLimits
                                        sourceText:[NSString stringWithFormat:@"Offline JSONL (%@)", [event[@"source_path"] lastPathComponent]]
                                         timestamp:timestamp];
}

- (NSDictionary *)latestOfflineUsageEvent {
    NSArray<NSURL *> *files = [self recentCodexUsageFiles];
    NSDictionary *latest = nil;
    for (NSURL *fileURL in files) {
        for (NSData *line in [self candidateOfflineLinesFromFile:fileURL]) {
            id json = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
            if (![json isKindOfClass:[NSDictionary class]]) { continue; }
            NSDictionary *payload = [json[@"payload"] isKindOfClass:[NSDictionary class]] ? json[@"payload"] : nil;
            if (![payload[@"type"] isEqualToString:@"token_count"] ||
                ![payload[@"rate_limits"] isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            NSMutableDictionary *event = [@{
                @"timestamp": json[@"timestamp"] ?: @"",
                @"rate_limits": payload[@"rate_limits"],
                @"source_path": fileURL.path ?: @""
            } mutableCopy];
            if (latest == nil || [event[@"timestamp"] compare:(latest[@"timestamp"] ?: @"")] == NSOrderedDescending) {
                latest = event;
            }
            break;
        }
    }
    return latest;
}

- (NSArray<NSURL *> *)recentCodexUsageFiles {
    NSString *codexHome = NSProcessInfo.processInfo.environment[@"CODEX_HOME"];
    if (codexHome.length == 0) {
        codexHome = [@"~/.codex" stringByExpandingTildeInPath];
    }
    NSURL *sessionsURL = [NSURL fileURLWithPath:[codexHome stringByAppendingPathComponent:@"sessions"]];
    NSDirectoryEnumerator<NSURL *> *enumerator = [NSFileManager.defaultManager enumeratorAtURL:sessionsURL
                                                                    includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                                                                                       options:0
                                                                                  errorHandler:nil];
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (NSURL *url in enumerator) {
        if (![url.pathExtension isEqualToString:@"jsonl"]) { continue; }
        NSDate *date = nil;
        [url getResourceValue:&date forKey:NSURLContentModificationDateKey error:nil];
        [entries addObject:@{@"url": url, @"date": date ?: NSDate.distantPast}];
    }
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [right[@"date"] compare:left[@"date"]];
    }];
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    NSUInteger count = MIN(entries.count, 150);
    for (NSUInteger index = 0; index < count; index++) {
        [urls addObject:entries[index][@"url"]];
    }
    return urls;
}

- (NSArray<NSData *> *)candidateOfflineLinesFromFile:(NSURL *)fileURL {
    NSData *data = [NSData dataWithContentsOfURL:fileURL options:NSDataReadingMappedIfSafe error:nil];
    if (data.length == 0) { return @[]; }
    NSUInteger tailBytes = MIN(data.length, (NSUInteger)(4 * 1024 * 1024));
    NSData *tail = [data subdataWithRange:NSMakeRange(data.length - tailBytes, tailBytes)];
    NSString *text = [[NSString alloc] initWithData:tail encoding:NSUTF8StringEncoding];
    if (text.length == 0) { return @[]; }
    NSArray<NSString *> *rawLines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSMutableArray<NSData *> *lines = [NSMutableArray array];
    for (NSString *line in [rawLines reverseObjectEnumerator]) {
        if ([line containsString:@"token_count"] && [line containsString:@"rate_limits"]) {
            NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
            if (lineData != nil) { [lines addObject:lineData]; }
        }
    }
    return lines;
}

- (NSDictionary *)buildCodexStateFromRateLimitsResult:(NSDictionary *)result sourceText:(NSString *)sourceText timestamp:(NSDate *)timestamp {
    NSDictionary *snapshot = [self preferredCodexSnapshotFromResult:result];
    if (snapshot == nil) {
        return nil;
    }
    NSMutableDictionary *state = [[self buildCodexStateFromSnapshot:snapshot sourceText:sourceText timestamp:timestamp appServerKeys:YES] mutableCopy];
    NSString *resetCredits = [self resetCreditsSummary:result[@"rateLimitResetCredits"]];
    if (resetCredits.length > 0) { state[@"reset_credits_summary"] = resetCredits; }
    NSArray *summaries = [self limitSummariesFromResult:result];
    if (summaries.count > 0) { state[@"limit_summaries"] = summaries; }
    NSArray *scoped = [self codexScopedLimitsFromResult:result excludingSnapshot:snapshot];
    if (scoped.count > 0) { state[@"scoped_limits"] = scoped; }
    return state;
}

// Structured rows for every additional limit the app-server reports beyond
// the preferred one (e.g. per-model limits like GPT-5.3-Codex-Spark), in the
// same {label, used_percent, resets_at} shape as Claude's scoped rows so the
// menu and the iOS app render them as bars.
- (NSArray<NSDictionary *> *)codexScopedLimitsFromResult:(NSDictionary *)result excludingSnapshot:(NSDictionary *)preferred {
    NSDictionary *byLimitId = [result[@"rateLimitsByLimitId"] isKindOfClass:[NSDictionary class]] ? result[@"rateLimitsByLimitId"] : nil;
    if (byLimitId.count == 0) {
        return @[];
    }
    NSString *preferredId = [self stringFromDictionary:preferred keys:@[@"limitId"]];
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    for (id key in [[byLimitId allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        NSDictionary *snapshot = [byLimitId[key] isKindOfClass:[NSDictionary class]] ? byLimitId[key] : nil;
        if (snapshot == nil) { continue; }
        NSString *limitId = [self stringFromDictionary:snapshot keys:@[@"limitId"]] ?: [key description];
        if (preferredId.length > 0 && [limitId isEqualToString:preferredId]) { continue; }
        NSString *name = [self stringFromDictionary:snapshot keys:@[@"limitName", @"limitId"]] ?: [key description];
        for (NSString *windowKey in @[@"primary", @"secondary"]) {
            NSDictionary *window = [self windowForSnapshot:snapshot key:windowKey];
            NSNumber *used = [self numberFromDictionary:window keys:@[@"usedPercent"]];
            if (used == nil) { continue; }
            NSMutableDictionary *row = [NSMutableDictionary dictionary];
            row[@"label"] = [NSString stringWithFormat:@"%@ %@", name, [self windowLabelForWindow:window appServerKeys:YES]];
            row[@"used_percent"] = used;
            NSNumber *reset = [self numberFromDictionary:window keys:@[@"resetsAt"]];
            if (reset != nil) { row[@"resets_at"] = reset; }
            [rows addObject:row];
        }
    }
    return rows;
}

- (NSDictionary *)buildCodexStateFromLegacySnapshot:(NSDictionary *)snapshot sourceText:(NSString *)sourceText timestamp:(NSDate *)timestamp {
    NSMutableDictionary *state = [[self buildCodexStateFromSnapshot:snapshot sourceText:sourceText timestamp:timestamp appServerKeys:NO] mutableCopy];
    NSArray *summaries = [self summariesForSnapshot:snapshot fallbackName:[self snapshotName:snapshot appServerKeys:NO] appServerKeys:NO];
    if (summaries.count > 0) { state[@"limit_summaries"] = summaries; }
    return state;
}

- (NSDictionary *)buildCodexStateFromSnapshot:(NSDictionary *)snapshot
                                   sourceText:(NSString *)sourceText
                                    timestamp:(NSDate *)timestamp
                                appServerKeys:(BOOL)appServerKeys {
    NSDictionary *primary = [self windowForSnapshot:snapshot key:@"primary"];
    NSDictionary *secondary = [self windowForSnapshot:snapshot key:@"secondary"];
    NSNumber *primaryUsed = [self numberFromDictionary:primary keys:appServerKeys ? @[@"usedPercent"] : @[@"used_percent"]];
    NSNumber *primaryReset = [self numberFromDictionary:primary keys:appServerKeys ? @[@"resetsAt"] : @[@"resets_at"]];
    NSNumber *secondaryUsed = [self numberFromDictionary:secondary keys:appServerKeys ? @[@"usedPercent"] : @[@"used_percent"]];
    NSNumber *secondaryReset = [self numberFromDictionary:secondary keys:appServerKeys ? @[@"resetsAt"] : @[@"resets_at"]];

    NSMutableDictionary *state = [@{
        @"ok": @YES,
        @"updated_summary": [self updatedSummaryForDate:timestamp],
        @"source_summary": [NSString stringWithFormat:@"Source: %@", sourceText ?: @"unknown"]
    } mutableCopy];

    if (primaryUsed != nil) { state[@"primary_used_percent"] = primaryUsed; }
    if (primaryReset != nil) { state[@"primary_resets_at"] = primaryReset; }
    if (secondaryUsed != nil) { state[@"secondary_used_percent"] = secondaryUsed; }
    if (secondaryReset != nil) { state[@"secondary_resets_at"] = secondaryReset; }

    // Real window durations (e.g. 300 min -> "5h", 10080 -> "7d") so the menu
    // labels the windows accurately instead of assuming "daily".
    if (primary != nil) {
        state[@"primary_window_label"] = [self windowLabelForWindow:primary appServerKeys:appServerKeys];
    }
    if (secondary != nil) {
        state[@"secondary_window_label"] = [self windowLabelForWindow:secondary appServerKeys:appServerKeys];
    }

    NSString *weekly = [self codexWeeklySummary:secondary appServerKeys:appServerKeys];
    if (weekly.length > 0) { state[@"weekly_summary"] = weekly; }

    NSString *credits = [self creditsSummary:[self dictionaryFromSnapshot:snapshot key:@"credits"]];
    if (credits.length > 0) { state[@"credits_summary"] = credits; }

    NSString *plan = [self stringFromDictionary:snapshot keys:appServerKeys ? @[@"planType"] : @[@"plan_type"]];
    if (plan.length > 0) { state[@"plan_summary"] = [NSString stringWithFormat:@"Plan: %@", plan]; }

    NSString *monthly = [self monthlySummary:[self dictionaryFromSnapshot:snapshot key:@"individualLimit"]];
    if (monthly.length > 0) { state[@"monthly_summary"] = monthly; }

    if (primaryUsed == nil && secondaryUsed == nil && credits.length == 0 && monthly.length == 0) {
        return @{ @"ok": @NO, @"error": @"Codex snapshot had no usable windows" };
    }
    return state;
}

- (NSDictionary *)preferredCodexSnapshotFromResult:(NSDictionary *)result {
    NSDictionary *byLimitId = [result[@"rateLimitsByLimitId"] isKindOfClass:[NSDictionary class]] ? result[@"rateLimitsByLimitId"] : nil;
    NSDictionary *codex = [byLimitId[@"codex"] isKindOfClass:[NSDictionary class]] ? byLimitId[@"codex"] : nil;
    if (codex != nil) { return codex; }
    if (byLimitId.count > 0) {
        for (id key in [[byLimitId allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            if ([byLimitId[key] isKindOfClass:[NSDictionary class]]) { return byLimitId[key]; }
        }
    }
    return [result[@"rateLimits"] isKindOfClass:[NSDictionary class]] ? result[@"rateLimits"] : nil;
}

- (NSArray<NSString *> *)limitSummariesFromResult:(NSDictionary *)result {
    NSDictionary *byLimitId = [result[@"rateLimitsByLimitId"] isKindOfClass:[NSDictionary class]] ? result[@"rateLimitsByLimitId"] : nil;
    if (byLimitId.count == 0) {
        NSDictionary *single = [result[@"rateLimits"] isKindOfClass:[NSDictionary class]] ? result[@"rateLimits"] : nil;
        return single != nil ? [self summariesForSnapshot:single fallbackName:@"Codex" appServerKeys:YES] : @[];
    }
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    for (id key in [[byLimitId allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        NSDictionary *snapshot = [byLimitId[key] isKindOfClass:[NSDictionary class]] ? byLimitId[key] : nil;
        if (snapshot == nil) { continue; }
        [items addObjectsFromArray:[self summariesForSnapshot:snapshot fallbackName:[key description] appServerKeys:YES]];
    }
    return items;
}

- (NSArray<NSString *> *)summariesForSnapshot:(NSDictionary *)snapshot fallbackName:(NSString *)fallbackName appServerKeys:(BOOL)appServerKeys {
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    NSString *name = [self snapshotName:snapshot appServerKeys:appServerKeys] ?: fallbackName ?: @"Codex";
    NSDictionary *primary = [self windowForSnapshot:snapshot key:@"primary"];
    if (primary != nil) {
        NSString *window = [self windowLabelForWindow:primary appServerKeys:appServerKeys];
        [items addObject:[self rateLimitSummaryWithLabel:[NSString stringWithFormat:@"%@ %@", name, window] window:primary appServerKeys:appServerKeys]];
    }
    NSDictionary *secondary = [self windowForSnapshot:snapshot key:@"secondary"];
    if (secondary != nil) {
        NSString *window = [self windowLabelForWindow:secondary appServerKeys:appServerKeys];
        [items addObject:[self rateLimitSummaryWithLabel:[NSString stringWithFormat:@"%@ %@", name, window] window:secondary appServerKeys:appServerKeys]];
    }
    return items;
}

- (NSDictionary *)windowForSnapshot:(NSDictionary *)snapshot key:(NSString *)key {
    id value = snapshot[key];
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

- (NSDictionary *)dictionaryFromSnapshot:(NSDictionary *)snapshot key:(NSString *)key {
    id value = snapshot[key];
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

- (NSString *)snapshotName:(NSDictionary *)snapshot appServerKeys:(BOOL)appServerKeys {
    NSString *name = [self stringFromDictionary:snapshot keys:appServerKeys ? @[@"limitName", @"limitId"] : @[@"limit_name", @"limit_id"]];
    return name.length > 0 ? name : @"Codex";
}

- (NSString *)rateLimitSummaryWithLabel:(NSString *)label window:(NSDictionary *)window appServerKeys:(BOOL)appServerKeys {
    if (window == nil) {
        return [NSString stringWithFormat:@"%@: unavailable", label ?: @"Codex"];
    }
    NSNumber *used = [self numberFromDictionary:window keys:appServerKeys ? @[@"usedPercent"] : @[@"used_percent"]];
    NSNumber *reset = [self numberFromDictionary:window keys:appServerKeys ? @[@"resetsAt"] : @[@"resets_at"]];
    return [NSString stringWithFormat:@"%@: %@, resets %@", label ?: @"Codex", [self percentSummaryTextForUsedPercent:used], [self resetLabelForSeconds:reset includeDate:NO]];
}

- (NSString *)codexWeeklySummary:(NSDictionary *)window appServerKeys:(BOOL)appServerKeys {
    if (window == nil) { return nil; }
    NSNumber *used = [self numberFromDictionary:window keys:appServerKeys ? @[@"usedPercent"] : @[@"used_percent"]];
    NSNumber *reset = [self numberFromDictionary:window keys:appServerKeys ? @[@"resetsAt"] : @[@"resets_at"]];
    return [NSString stringWithFormat:@"Weekly: %@, resets %@", [self percentSummaryTextForUsedPercent:used], [self resetLabelForSeconds:reset includeDate:YES]];
}

- (NSString *)percentSummaryTextForUsedPercent:(NSNumber *)used {
    if (used == nil) {
        return [[self metricMode] isEqualToString:MetricModeUsed] ? @"--% used" : @"--% left";
    }
    double usedValue = MAX(0.0, MIN(100.0, used.doubleValue));
    if ([[self metricMode] isEqualToString:MetricModeUsed]) {
        return [NSString stringWithFormat:@"%.0f%% used", usedValue];
    }
    double leftValue = MAX(0.0, MIN(100.0, 100.0 - usedValue));
    return [NSString stringWithFormat:@"%.0f%% left, %.0f%% used", leftValue, usedValue];
}

- (NSString *)windowLabelForWindow:(NSDictionary *)window appServerKeys:(BOOL)appServerKeys {
    NSNumber *minutes = [self numberFromDictionary:window keys:appServerKeys ? @[@"windowDurationMins"] : @[@"window_minutes"]];
    if (minutes == nil) { return @"window"; }
    NSInteger value = minutes.integerValue;
    if (value > 0 && value % 1440 == 0) { return [NSString stringWithFormat:@"%ldd", (long)(value / 1440)]; }
    if (value > 0 && value % 60 == 0) { return [NSString stringWithFormat:@"%ldh", (long)(value / 60)]; }
    return [NSString stringWithFormat:@"%ldm", (long)value];
}

- (NSString *)creditsSummary:(NSDictionary *)credits {
    if (credits == nil) { return nil; }
    NSNumber *unlimited = [credits[@"unlimited"] respondsToSelector:@selector(boolValue)] ? credits[@"unlimited"] : nil;
    if (unlimited.boolValue) { return @"Credits: unlimited"; }
    id balance = credits[@"balance"];
    if ([balance isKindOfClass:[NSString class]] && [balance length] > 0) {
        return [NSString stringWithFormat:@"Credits: %@", balance];
    }
    if ([balance respondsToSelector:@selector(doubleValue)]) {
        return [NSString stringWithFormat:@"Credits: %.2f", [balance doubleValue]];
    }
    NSNumber *hasCredits = [credits[@"hasCredits"] respondsToSelector:@selector(boolValue)] ? credits[@"hasCredits"] : nil;
    if (hasCredits != nil && !hasCredits.boolValue) { return @"Credits: none"; }
    return nil;
}

- (NSString *)resetCreditsSummary:(id)resetCredits {
    if (![resetCredits isKindOfClass:[NSDictionary class]]) { return nil; }
    NSNumber *available = [self numberFromDictionary:resetCredits keys:@[@"availableCount"]];
    if (available == nil) { return nil; }
    return [NSString stringWithFormat:@"Usage resets: %ld available", (long)available.integerValue];
}

- (NSString *)monthlySummary:(NSDictionary *)monthly {
    if (monthly == nil) { return nil; }
    NSString *used = [self stringFromDictionary:monthly keys:@[@"used"]];
    NSString *limit = [self stringFromDictionary:monthly keys:@[@"limit"]];
    NSNumber *remaining = [self numberFromDictionary:monthly keys:@[@"remainingPercent"]];
    NSNumber *reset = [self numberFromDictionary:monthly keys:@[@"resetsAt"]];
    if (used.length == 0 && limit.length == 0 && remaining == nil) { return nil; }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (used.length > 0 && limit.length > 0) { [parts addObject:[NSString stringWithFormat:@"%@ of %@", used, limit]]; }
    if (remaining != nil) { [parts addObject:[NSString stringWithFormat:@"%ld%% left", (long)remaining.integerValue]]; }
    if (reset != nil) { [parts addObject:[NSString stringWithFormat:@"resets %@", [self resetLabelForSeconds:reset includeDate:YES]]]; }
    return [NSString stringWithFormat:@"Monthly: %@", [parts componentsJoinedByString:@", "]];
}

#pragma mark - Shared formatting helpers

- (NSNumber *)numberFromDictionary:(NSDictionary *)dictionary keys:(NSArray<NSString *> *)keys {
    if (![dictionary isKindOfClass:[NSDictionary class]]) { return nil; }
    for (NSString *key in keys) {
        id value = dictionary[key];
        if ([value respondsToSelector:@selector(doubleValue)] && ![value isKindOfClass:[NSString class]]) {
            return @([value doubleValue]);
        }
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
            return @([value doubleValue]);
        }
    }
    return nil;
}

- (NSString *)stringFromDictionary:(NSDictionary *)dictionary keys:(NSArray<NSString *> *)keys {
    if (![dictionary isKindOfClass:[NSDictionary class]]) { return nil; }
    for (NSString *key in keys) {
        id value = dictionary[key];
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) { return value; }
    }
    return nil;
}

- (NSString *)resetLabelForSeconds:(NSNumber *)seconds includeDate:(BOOL)includeDate {
    if (seconds == nil) { return @"unknown"; }
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:seconds.doubleValue];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = includeDate ? NSDateFormatterMediumStyle : NSDateFormatterNoStyle;
    formatter.timeStyle = includeDate ? NSDateFormatterNoStyle : NSDateFormatterShortStyle;
    return [formatter stringFromDate:date];
}

- (NSString *)updatedSummaryForDate:(NSDate *)date {
    if (date == nil) { return @"Updated: unknown"; }
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterNoStyle;
    formatter.timeStyle = NSDateFormatterShortStyle;
    return [NSString stringWithFormat:@"Updated: %@", [formatter stringFromDate:date]];
}

- (NSDate *)dateFromISOString:(id)value {
    if (![value isKindOfClass:[NSString class]]) { return nil; }
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    NSDate *date = [formatter dateFromString:value];
    if (date != nil) { return date; }
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    return [formatter dateFromString:value];
}

#pragma mark - Launch at login

- (BOOL)launchAtLoginEnabled {
    if (@available(macOS 13.0, *)) {
        return SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
    }
    return NO;
}

- (void)toggleLaunchAtLogin {
    self.launchAtLoginError = nil;
    if (@available(macOS 13.0, *)) {
        NSError *error = nil;
        BOOL ok = NO;
        if (SMAppService.mainAppService.status == SMAppServiceStatusEnabled) {
            ok = [SMAppService.mainAppService unregisterAndReturnError:&error];
        } else {
            ok = [SMAppService.mainAppService registerAndReturnError:&error];
        }
        if (!ok) { self.launchAtLoginError = error.localizedDescription ?: @"could not update"; }
    } else {
        self.launchAtLoginError = @"requires macOS 13 or newer";
    }
}

- (void)quit {
    [NSApp terminate:nil];
}

@end

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
