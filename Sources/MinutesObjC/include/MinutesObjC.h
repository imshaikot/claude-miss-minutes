#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns the reason of any Objective-C exception it raised,
/// or nil. AVFoundation reports some runtime conditions (an audio device that
/// vanished mid-sentence) as exceptions, which Swift cannot catch on its own.
NSString *_Nullable MMCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
