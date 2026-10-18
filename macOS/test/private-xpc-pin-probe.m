// Disposable, unprivileged anonymous XPC check. No installer service is used.
#import <Foundation/Foundation.h>
#import <stdatomic.h>

@protocol PrivatePinPing
- (void)ping:(void (^)(NSString *))reply;
@end

@interface PinProbe : NSObject <NSXPCListenerDelegate, PrivatePinPing>
@property(nonatomic, copy) NSString *clientRequirement;
@property(nonatomic, strong) NSXPCConnection *accepted;
@end

static atomic_int invocations;
static atomic_bool finished;
static atomic_bool received;
static atomic_bool failed;
static atomic_bool signingFailure;

@implementation PinProbe
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
  [connection setCodeSigningRequirement:self.clientRequirement];
  connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(PrivatePinPing)];
  connection.exportedObject = self;
  self.accepted = connection;
  [connection activate];
  return YES;
}
- (void)ping:(void (^)(NSString *))reply {
  atomic_fetch_add(&invocations, 1);
  reply(@"pong");
}
@end

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc != 4) return 64;
    PinProbe *probe = [PinProbe new];
    probe.clientRequirement = [NSString stringWithUTF8String:argv[1]];
    NSXPCListener *listener = [NSXPCListener anonymousListener];
    listener.delegate = probe;
    [listener activate];
    NSXPCConnection *client = [[NSXPCConnection alloc] initWithListenerEndpoint:listener.endpoint];
    [client setCodeSigningRequirement:[NSString stringWithUTF8String:argv[2]]];
    client.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(PrivatePinPing)];
    client.invalidationHandler = ^{ atomic_store(&failed, true); atomic_store(&finished, true); };
    [client activate];
    id<PrivatePinPing> remote = [client remoteObjectProxyWithErrorHandler:^(NSError *error) {
      fprintf(stderr, "XPC rejected: %s (%ld)\n", error.domain.UTF8String, (long)error.code);
      if ([error.domain isEqualToString:NSCocoaErrorDomain] && error.code == NSXPCConnectionCodeSigningRequirementFailure) {
        atomic_store(&signingFailure, true);
      }
      atomic_store(&failed, true);
      atomic_store(&finished, true);
    }];
    [remote ping:^(NSString *reply) {
      atomic_store(&received, [reply isEqualToString:@"pong"]);
      atomic_store(&finished, true);
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!atomic_load(&finished) && deadline.timeIntervalSinceNow > 0) {
      [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    BOOL expectSuccess = strcmp(argv[3], "allow") == 0;
    BOOL denyClient = strcmp(argv[3], "deny-client") == 0;
    // XPC validates inbound messages. A client may send a harmless ping before
    // rejecting a server's reply. Production requires that ping before secrets.
    BOOL ok = expectSuccess
      ? atomic_load(&received) && atomic_load(&invocations) == 1
      : !atomic_load(&received) && atomic_load(&failed)
        && (denyClient ? atomic_load(&invocations) == 0 : atomic_load(&signingFailure));
    [client invalidate];
    [probe.accepted invalidate];
    [listener invalidate];
    printf("%s: invoked=%d reply=%d rejected=%d\n", ok ? "PASS" : "FAIL", atomic_load(&invocations), atomic_load(&received), atomic_load(&failed));
    return ok ? 0 : 1;
  }
}
