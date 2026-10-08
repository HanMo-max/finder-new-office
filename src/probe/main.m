#import <Foundation/Foundation.h>

// Exercises the document writers without launching the Finder extension.
// The output directory comes from $OUTDIR so the check never writes anywhere fixed.
#import "../extension/NewDocSync.m"

int main(void) {
    @autoreleasepool {
        NewDocSync *sync = [[NewDocSync alloc] init];
        NSString *dir = [[[NSProcessInfo processInfo] environment] objectForKey:@"OUTDIR"];
        if (dir.length == 0) {
            fprintf(stderr, "OUTDIR is not set\n");
            return 2;
        }
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES attributes:nil error:nil];

        NSError *error = nil;
        NSDictionary<NSString *, NSString *> *cases = @{
            @"probe.docx": @"docx",
            @"probe.xlsx": @"xlsx",
            @"probe.pptx": @"pptx",
        };
        BOOL allOK = YES;
        for (NSString *file in cases) {
            NSString *path = [dir stringByAppendingPathComponent:file];
            BOOL ok = NO;
            if ([cases[file] isEqualToString:@"docx"]) ok = [sync writeDocx:path error:&error];
            else if ([cases[file] isEqualToString:@"xlsx"]) ok = [sync writeXlsx:path error:&error];
            else ok = [sync writePptx:path error:&error];
            fprintf(stderr, "%s -> %s\n", file.UTF8String, ok ? "OK" : "FAIL");
            allOK = allOK && ok;
            error = nil;
        }
        // Exercise real collision handling, including a write-time collision.
        NSString *wordPath = [dir stringByAppendingPathComponent:@"probe.docx"];
        NSData *before = [NSData dataWithContentsOfFile:wordPath];
        error = nil;
        BOOL overwriteAccepted = [sync writeDocx:wordPath error:&error];
        BOOL preserved = !overwriteAccepted && error != nil &&
            [before isEqualToData:[NSData dataWithContentsOfFile:wordPath]];
        BOOL numbered = [uniqueName(dir, @"probe", @"docx") isEqualToString:@"probe 2.docx"];
        fprintf(stderr, "collision handling -> %s\n", preserved && numbered ? "OK" : "FAIL");
        allOK = allOK && preserved && numbered;
        return allOK ? 0 : 1;
    }
}
