#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
int main(int argc, const char **argv) {
 @autoreleasepool {
  if(argc != 2) return 2;
  NSBundle *bundle = [NSBundle bundleWithPath:[NSString stringWithUTF8String:argv[1]]];
  printf("bundle=%s\n",bundle ? "found" : "missing");
  printf("executable=%s\n",bundle.executablePath.UTF8String ?: "(nil)");
  printf("ordinary display name=%s\n",[bundle.infoDictionary[@"CFBundleDisplayName"] UTF8String] ?: "(nil)");
  printf("localized dictionary=%s\n",bundle.localizedInfoDictionary.description.UTF8String ?: "(nil)");
  NSString *iconName = bundle.infoDictionary[@"CFBundleIconFile"];
  if (![iconName isEqualToString:@"AuroraInstaller.icns"]) return 1;
  NSString *iconPath = [bundle pathForResource:iconName ofType:nil];
  NSImage *icon = iconPath ? [[NSImage alloc] initWithContentsOfFile:iconPath] : nil;
  if (!icon.valid || icon.size.width <= 0 || icon.size.height <= 0) return 1;
  printf("PASS bundle icon lookup and native image decoding\n");
  @try {
   NSMutableDictionary *item=[NSMutableDictionary new];
   // Exact sequence at Recovery Springboard 0x100004ce0..0x100004d04.
   [item setObject:bundle.localizedInfoDictionary[@"CFBundleDisplayName"] forKey:@"BundleDisplayName"];
   printf("PASS Springboard display-name lookup: %s\n",[item[@"BundleDisplayName"] UTF8String]);
   return 0;
  } @catch(NSException *exception) {
   printf("FAIL %s: %s\n",exception.name.UTF8String,exception.reason.UTF8String);
   return 1;
  }
 }
}
