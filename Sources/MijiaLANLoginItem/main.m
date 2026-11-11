#import <AppKit/AppKit.h>

int main(void) {
    @autoreleasepool {
        NSURL *loginItems = NSBundle.mainBundle.bundleURL.URLByDeletingLastPathComponent;
        NSURL *appURL = loginItems.URLByDeletingLastPathComponent
            .URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
        NSString *identifier = [NSBundle bundleWithURL:appURL].bundleIdentifier;
        if (!identifier) {
            return EXIT_FAILURE;
        }
        if ([NSRunningApplication runningApplicationsWithBundleIdentifier:identifier].count != 0) {
            return EXIT_SUCCESS;
        }

        NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
        configuration.activates = NO;
        configuration.addsToRecentItems = NO;
        configuration.createsNewApplicationInstance = NO;
        [NSWorkspace.sharedWorkspace openApplicationAtURL:appURL configuration:configuration
                                         completionHandler:^(__unused NSRunningApplication *application, NSError *error) {
            if (error) {
                NSLog(@"Could not launch MijiaLAN at login: %@", error);
            }
            exit(error ? EXIT_FAILURE : EXIT_SUCCESS);
        }];
    }
    dispatch_main();
}
