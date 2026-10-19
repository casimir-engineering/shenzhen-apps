#include "bindings/bindings.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

// What starts the app on iOS (a Friends link, src/friends_links.rs, or a file opened in it) comes with its first
// scene, in the scene's connection options. The windowing library's scene delegate hears what reaches a running app
// (scene:openURLContexts:) but not these, so they are handed to that same method once the scene has connected. The
// delegate class exists once the app has finished launching, and the first scene connects after that.
static void forwardLaunchURLs(void) {
	Class delegate = NSClassFromString(@"TaoSceneDelegate");
	SEL connect = @selector(scene:willConnectToSession:options:);
	SEL open = @selector(scene:openURLContexts:);
	Method method = delegate ? class_getInstanceMethod(delegate, connect) : NULL;
	if (!method || !class_getInstanceMethod(delegate, open)) return;
	typedef void (*Connect)(id, SEL, UIScene *, UISceneSession *, UISceneConnectionOptions *);
	typedef void (*Open)(id, SEL, UIScene *, NSSet<UIOpenURLContext *> *);
	Connect connected = (Connect)method_getImplementation(method);
	method_setImplementation(method, imp_implementationWithBlock(
		^(id self, UIScene *scene, UISceneSession *session, UISceneConnectionOptions *options) {
			connected(self, connect, scene, session, options);
			if (options.URLContexts.count) ((Open)objc_msgSend)(self, open, scene, options.URLContexts);
		}));
}

int main(int argc, char * argv[]) {
	__block id launched = [NSNotificationCenter.defaultCenter
		addObserverForName:UIApplicationDidFinishLaunchingNotification
		            object:nil
		             queue:nil
		        usingBlock:^(NSNotification *note) {
			forwardLaunchURLs();
			[NSNotificationCenter.defaultCenter removeObserver:launched];
		}];
	ffi::start_app();
	return 0;
}
