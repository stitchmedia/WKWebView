#import <objc/runtime.h>
#import "AppDelegate.h"
#import "MyMainViewController.h"
#import "GCDWebServer.h"
#import "GCDWebServerDataRequest.h"
#import "GCDWebServerDataResponse.h"
#import "GCDWebServerFileRequest.h"
#import "GCDWebServerPrivate.h"
#import "GCDWebServerFileResponse.h"

// need to swap out a method, so swizzling it here
static void swizzleMethod(Class class, SEL destinationSelector, SEL sourceSelector);

@implementation AppDelegate (WKWebViewPolyfill)

NSString *const FileSchemaConstant = @"file://";
NSString *const ServerCreatedNotificationName = @"WKWebView.WebServer.Created";
GCDWebServer* _webServer;
NSMutableDictionary* _webServerOptions;
NSString* appDataFolder;

+ (void)load {
    // Swap in our own viewcontroller which loads the wkwebview, but only in case we're running iOS 8+
    if (IsAtLeastiOSVersion(@"8.0")) {
        swizzleMethod([AppDelegate class],
                      @selector(application:didFinishLaunchingWithOptions:),
                      @selector(my_application:didFinishLaunchingWithOptions:));
    }
}

- (BOOL)my_application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
    [self createWindowAndStartWebServer:true];
    return YES;
}

- (void) createWindowAndStartWebServer:(BOOL) startWebServer {
    CGRect screenBounds = [[UIScreen mainScreen] bounds];

    self.window = [[UIWindow alloc] initWithFrame:screenBounds];
    self.window.autoresizesSubviews = YES;
    MyMainViewController *myMainViewController = [[MyMainViewController alloc] init];
    self.viewController = myMainViewController;
    self.window.rootViewController = myMainViewController;
    [self.window makeKeyAndVisible];
    appDataFolder = [[NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByDeletingLastPathComponent];

    // Note: the embedded webserver is still needed for iOS 9. It's not needed to load index.html,
    //       but we need it to ajax-load files (file:// protocol has no origin, leading to CORS issues).
    NSString *directoryPath = myMainViewController.wwwFolderName;
    _webServer = [[GCDWebServer alloc] init];
    _webServerOptions = [NSMutableDictionary dictionary];

    // Add GET handler for local "www/" directory
    [_webServer addGETHandlerForBasePath:@"/"
                           directoryPath:directoryPath
                           indexFilename:nil
                                cacheAge:30
                      allowRangeRequests:YES];

    [[NSNotificationCenter defaultCenter] postNotificationName:ServerCreatedNotificationName object: @[myMainViewController, _webServer]];

    [self addHandlerForPath:@"/Library/"];
    [self addHandlerForPath:@"/Documents/"];
    [self addHandlerForPath:@"/tmp/"];

    // Initialize Server startup
    if (startWebServer) {
      [self startServer];
    }

    // Update Swizzled ViewController with port currently used by local Server
    [myMainViewController setServerPort:_webServer.port];
}

- (void)addHandlerForPath:(NSString *) path {
  [_webServer addHandlerForMethod:@"GET"
                        pathRegex:[@".*" stringByAppendingString:path]
                     requestClass:[GCDWebServerRequest class]
                     processBlock:^GCDWebServerResponse *(GCDWebServerRequest* request) {
                       NSString *fileLocation = request.URL.path;
                       if ([fileLocation hasPrefix:path]) {
                         fileLocation = [appDataFolder stringByAppendingString:request.URL.path];
                       }

                       fileLocation = [fileLocation stringByReplacingOccurrencesOfString:FileSchemaConstant withString:@""];
                       if (![[NSFileManager defaultManager] fileExistsAtPath:fileLocation]) {
                           return nil;
                       }

                       return [GCDWebServerFileResponse responseWithFile:fileLocation byteRange:request.byteRange];
                     }
   ];

   [_webServer addHandlerForMethod:@"GET" path:@"/proxy" requestClass:GCDWebServerDataRequest.self asyncProcessBlock:^(GCDWebServerRequest *request, GCDWebServerCompletionBlock completionBlock) {
      NSString *str = [request.headers objectForKey:@"x-url"];
      if (!str) {
         str = [request.query valueForKey:@"url"];
      }
      str = [str stringByReplacingOccurrencesOfString:@"'" withString:@"%27"];
      NSURL *url = [NSURL URLWithString:str];
      NSMutableURLRequest *req = [[NSMutableURLRequest alloc] init];

      [req setHTTPShouldHandleCookies:false];
      [req setCachePolicy:NSURLRequestReloadIgnoringLocalCacheData];
      [req setURL:url];
      [req setHTTPMethod:@"GET"];

      NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
      for (NSString* key in request.headers) {
         id k = [key lowercaseString];
         if ([k isEqualToString: @"connection"] ||
             [k isEqualToString: @"content-length"] ||
             [k isEqualToString: @"content-encoding"] ||
             [k isEqualToString: @"host"]) {
            continue;
         }

          if ([k isEqualToString:@"x-cookie"]) {
              k = @"cookie";
          }

         id value = [request.headers objectForKey:key];
         [req setValue:value forHTTPHeaderField:k];
      }

       if (request.query[@"cookie"]) {
           [req setValue:request.query[@"cookie"] forHTTPHeaderField:@"cookie"];
       }

      NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
      config.requestCachePolicy = NSURLRequestReloadIgnoringCacheData;
       NSURLSessionDataTask *task;
       task = [session dataTaskWithRequest:req
                                              completionHandler:
                                    ^(NSData *respz, NSURLResponse *urlResponse, NSError *requestError) {
                                       NSData *resp = respz;
                                       NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *) urlResponse;
                                       NSDictionary *headers = [httpResponse allHeaderFields];

                                       if (requestError != nil) {
                                          resp = [[requestError localizedDescription] dataUsingEncoding:NSUnicodeStringEncoding];
                                       }

                                       GCDWebServerDataResponse *response = [[GCDWebServerDataResponse alloc] initWithData:resp contentType:@"text/plain"];

                                       response.statusCode = httpResponse.statusCode;

                                       for (NSString* key in headers) {
                                          id k = [key lowercaseString];
                                          if ([k isEqualToString: @"connection"] ||
                                              [k isEqualToString: @"content-length"] ||
                                              [k isEqualToString: @"content-encoding"] ||
                                              [k isEqualToString: @"host"]) {
                                             continue;
                                          }

                                        id value = [headers objectForKey:key];

                                        if (request.headers[@"x-internal"] && [k isEqualToString:@"set-cookie"]) {
                                             k = @"x-set-cookie";
                                           }

                                           if ([k isEqualToString:@"location"]) {
                                               if (request.headers[@"x-internal"]) {
                                                   k = @"x-location";
                                               } else {
                                                   value = [value stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet alphanumericCharacterSet]];
                                               }
                                           }

                                          [response setValue:value forAdditionalHeader:k];
                                       }

                                      if (headers[@"content-type"]) {
                                        response.contentType = headers[@"content-type"];
                                      }

                                       completionBlock(response);
                                    }];
      [task resume];
      }
   ];

    [_webServer addHandlerForMethod:@"GET" pathRegex:@"/proxy/.+" requestClass:GCDWebServerDataRequest.self asyncProcessBlock:^(GCDWebServerRequest *request, GCDWebServerCompletionBlock completionBlock) {
        NSString *str = [request.URL.path substringFromIndex:7];
        if (![str hasPrefix:@"http://"] && ![str hasPrefix:@"https://"]) {
            str = [@"http://" stringByAppendingString:str];
        }
        NSURL *url = [NSURL URLWithString:str];
        NSMutableURLRequest *req = [[NSMutableURLRequest alloc] init];

        [req setHTTPShouldHandleCookies:false];
        [req setCachePolicy:NSURLRequestReloadIgnoringLocalCacheData];
        [req setURL:url];
        [req setHTTPMethod:@"GET"];

        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        for (NSString* key in request.headers) {
            id k = [key lowercaseString];
            if ([k isEqualToString: @"connection"] ||
                [k isEqualToString: @"content-length"] ||
                [k isEqualToString: @"content-encoding"] ||
                [k isEqualToString: @"host"]) {
                continue;
            }

            if ([k isEqualToString:@"x-cookie"]) {
                k = @"cookie";
            }

            id value = [request.headers objectForKey:key];
            [req setValue:value forHTTPHeaderField:k];
        }

        if (request.query[@"cookie"]) {
            [req setValue:request.query[@"cookie"] forHTTPHeaderField:@"cookie"];
        }

        NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
        config.requestCachePolicy = NSURLRequestReloadIgnoringCacheData;
        NSURLSessionDataTask *task;
        task = [session dataTaskWithRequest:req
                          completionHandler:
                ^(NSData *respz, NSURLResponse *urlResponse, NSError *requestError) {
                    NSData *resp = respz;
                    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *) urlResponse;
                    NSDictionary *headers = [httpResponse allHeaderFields];

                    if (requestError != nil) {
                        resp = [[requestError localizedDescription] dataUsingEncoding:NSUnicodeStringEncoding];
                    }

                    GCDWebServerDataResponse *response = [[GCDWebServerDataResponse alloc] initWithData:resp contentType:@"text/plain"];

                    response.statusCode = httpResponse.statusCode;

                    for (NSString* key in headers) {
                        id k = [key lowercaseString];
                        if ([k isEqualToString: @"connection"] ||
                            [k isEqualToString: @"content-length"] ||
                            [k isEqualToString: @"content-encoding"] ||
                            [k isEqualToString: @"host"]) {
                            continue;
                        }

                        id value = [headers objectForKey:key];

                        if (request.headers[@"x-internal"] && [k isEqualToString:@"set-cookie"]) {
                            k = @"x-set-cookie";
                        }

                        if ([k isEqualToString:@"location"]) {
                            if (request.headers[@"x-internal"]) {
                                k = @"x-location";
                            } else {
                                value = [value stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet alphanumericCharacterSet]];
                            }
                        }

                        [response setValue:value forAdditionalHeader:k];
                    }

                    if (headers[@"content-type"]) {
                        response.contentType = headers[@"content-type"];
                    }

                    completionBlock(response);
                }];
        [task resume];
    }
     ];


   [_webServer addHandlerForMethod:@"POST" path:@"/proxy" requestClass:GCDWebServerDataRequest.self asyncProcessBlock:^(GCDWebServerRequest *request, GCDWebServerCompletionBlock completionBlock) {
      NSString *str = [request.headers objectForKey:@"x-url"];
      if (!str) {
         str = [request.query objectForKey:@"url"];
      }
      str = [str stringByReplacingOccurrencesOfString:@"'" withString:@"%27"];
      GCDWebServerDataRequest *mreq = (GCDWebServerDataRequest *) request;
      NSURL *url = [NSURL URLWithString:str];
      NSMutableURLRequest *req = [[NSMutableURLRequest alloc] init];

      [req setHTTPShouldHandleCookies:false];
      [req setCachePolicy:NSURLRequestReloadIgnoringLocalCacheData];
      [req setURL:url];
      [req setHTTPMethod:@"POST"];
      [req setHTTPBody:mreq.data];

      NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
      for (NSString* key in request.headers) {
         id k = [key lowercaseString];
         if ([k isEqualToString: @"connection"] ||
             [k isEqualToString: @"content-length"] ||
             [k isEqualToString: @"content-encoding"] ||
             [k isEqualToString: @"host"]) {
            continue;
         }

          if ([k isEqualToString:@"x-cookie"]) {
              k = @"cookie";
          }

         id value = [request.headers objectForKey:key];
         [req setValue:value forHTTPHeaderField:k];
      }

       if (request.query[@"cookie"]) {
           [req setValue:request.query[@"cookie"] forHTTPHeaderField:@"cookie"];
       }

      config.requestCachePolicy = NSURLRequestReloadIgnoringCacheData;
      NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
       NSURLSessionDataTask *task;
       task = [session dataTaskWithRequest:req
                                              completionHandler:
                                    ^(NSData *respz, NSURLResponse *urlResponse, NSError *requestError) {
                                       NSData *resp = respz;
                                       NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *) urlResponse;
                                       NSDictionary *headers = [httpResponse allHeaderFields];

                                       if (requestError != nil) {
                                          resp = [[requestError localizedDescription] dataUsingEncoding:NSUnicodeStringEncoding];
                                       }

                                       GCDWebServerDataResponse *response = [[GCDWebServerDataResponse alloc] initWithData:resp contentType:@"text/plain"];

                                       response.statusCode = httpResponse.statusCode;

                                       for (NSString* key in headers) {
                                          id k = [key lowercaseString];
                                           if ([k isEqualToString: @"connection"] ||
                                               [k isEqualToString: @"content-length"] ||
                                               [k isEqualToString: @"content-encoding"] ||
                                               [k isEqualToString: @"host"]) {
                                               continue;
                                           }
                                           id value = [headers objectForKey:key];

                                           if (request.headers[@"x-internal"] && [k isEqualToString:@"set-cookie"]) {
                                               k = @"x-set-cookie";
                                           }

                                           if ([k isEqualToString:@"location"]) {
                                               if (request.headers[@"x-internal"]) {
                                                   k = @"x-location";
                                               } else {
                                                   value = [value stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet alphanumericCharacterSet]];
                                               }
                                           }

                                           [response setValue:value forAdditionalHeader:k];
                                       }

                                       if (headers[@"content-type"]) {
                                         response.contentType = headers[@"content-type"];
                                       }

                                       completionBlock(response);
                                    }];
      [task resume];
   }
    ];

    [_webServer addHandlerForMethod:@"POST" pathRegex:@"/proxy/.+" requestClass:GCDWebServerDataRequest.self asyncProcessBlock:^(GCDWebServerRequest *request, GCDWebServerCompletionBlock completionBlock) {
        NSString *str = [request.URL.path substringFromIndex:7];
        if (![str hasPrefix:@"http://"] && ![str hasPrefix:@"https://"]) {
            str = [@"http://" stringByAppendingString:str];
        }
        str = [str stringByReplacingOccurrencesOfString:@"'" withString:@"%27"];
        GCDWebServerDataRequest *mreq = (GCDWebServerDataRequest *) request;
        NSURL *url = [NSURL URLWithString:str];
        NSMutableURLRequest *req = [[NSMutableURLRequest alloc] init];

        [req setHTTPShouldHandleCookies:false];
        [req setCachePolicy:NSURLRequestReloadIgnoringLocalCacheData];
        [req setURL:url];
        [req setHTTPMethod:@"POST"];
        [req setHTTPBody:mreq.data];

        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        for (NSString* key in request.headers) {
            id k = [key lowercaseString];
            if ([k isEqualToString: @"connection"] ||
                [k isEqualToString: @"content-length"] ||
                [k isEqualToString: @"content-encoding"] ||
                [k isEqualToString: @"host"]) {
                continue;
            }

            if ([k isEqualToString:@"x-cookie"]) {
                k = @"cookie";
            }

            id value = [request.headers objectForKey:key];
            [req setValue:value forHTTPHeaderField:k];
        }

        if (request.query[@"cookie"]) {
            [req setValue:request.query[@"cookie"] forHTTPHeaderField:@"cookie"];
        }

        config.requestCachePolicy = NSURLRequestReloadIgnoringCacheData;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
        NSURLSessionDataTask *task;
        task = [session dataTaskWithRequest:req
                          completionHandler:
                ^(NSData *respz, NSURLResponse *urlResponse, NSError *requestError) {
                    NSData *resp = respz;
                    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *) urlResponse;
                    NSDictionary *headers = [httpResponse allHeaderFields];

                    if (requestError != nil) {
                        resp = [[requestError localizedDescription] dataUsingEncoding:NSUnicodeStringEncoding];
                    }

                    GCDWebServerDataResponse *response = [[GCDWebServerDataResponse alloc] initWithData:resp contentType:@"text/plain"];

                    response.statusCode = httpResponse.statusCode;

                    for (NSString* key in headers) {
                        id k = [key lowercaseString];
                        if ([k isEqualToString: @"connection"] ||
                            [k isEqualToString: @"content-length"] ||
                            [k isEqualToString: @"content-encoding"] ||
                            [k isEqualToString: @"host"]) {
                            continue;
                        }
                        id value = [headers objectForKey:key];

                        if (request.headers[@"x-internal"] && [k isEqualToString:@"set-cookie"]) {
                            k = @"x-set-cookie";
                        }

                        if ([k isEqualToString:@"location"]) {
                            if (request.headers[@"x-internal"]) {
                                k = @"x-location";
                            } else {
                                value = [value stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet alphanumericCharacterSet]];
                            }
                        }

                        [response setValue:value forAdditionalHeader:k];
                    }

                    if (headers[@"content-type"]) {
                        response.contentType = headers[@"content-type"];
                    }

                    completionBlock(response);
                }];
        [task resume];
    }
     ];

}

- (BOOL)identity_application: (UIApplication *)application
                     openURL: (NSURL *)url
           sourceApplication: (NSString *)sourceApplication
                  annotation: (id)annotation {

    // call super
    return [self identity_application:application openURL:url sourceApplication:sourceApplication annotation:annotation];
}

- (void)startServer
{
    NSError *error = nil;

    // Enable this option to force the Server also to run when suspended
    //[_webServerOptions setObject:[NSNumber numberWithBool:NO] forKey:GCDWebServerOption_AutomaticallySuspendInBackground];

    [_webServerOptions setObject:[NSNumber numberWithBool:YES]
                          forKey:GCDWebServerOption_BindToLocalhost];

    // Initialize Server listening port, initially trying 12344 for backwards compatibility
    int httpPort = 12344;

    // Start Server
    do {
        [_webServerOptions setObject:[NSNumber numberWithInteger:httpPort++]
                              forKey:GCDWebServerOption_Port];
    } while(![_webServer startWithOptions:_webServerOptions error:&error]);

    if (error) {
        NSLog(@"Error starting http daemon: %@", error);
    } else {
        [GCDWebServer setLogLevel:kGCDWebServerLoggingLevel_Warning];
        NSLog(@"Started http daemon: %@ ", _webServer.serverURL);
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)redirectResponse
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))completionHandler
{
    completionHandler(nil);
}

@end


#pragma mark Swizzling

static void swizzleMethod(Class class, SEL destinationSelector, SEL sourceSelector) {
    Method destinationMethod = class_getInstanceMethod(class, destinationSelector);
    Method sourceMethod = class_getInstanceMethod(class, sourceSelector);

    // If the method doesn't exist, add it.  If it does exist, replace it with the given implementation.
    if (class_addMethod(class, destinationSelector, method_getImplementation(sourceMethod), method_getTypeEncoding(sourceMethod))) {
        class_replaceMethod(class, destinationSelector, method_getImplementation(destinationMethod), method_getTypeEncoding(destinationMethod));
    } else {
        method_exchangeImplementations(destinationMethod, sourceMethod);
    }
}

@implementation NSString (NSString_Extended)

- (NSString *)urlencode {
    NSMutableString *output = [NSMutableString string];
    const unsigned char *source = (const unsigned char *)[self UTF8String];
    int sourceLen = strlen((const char *)source);
    for (int i = 0; i < sourceLen; ++i) {
        const unsigned char thisChar = source[i];
        if (thisChar == ' '){
            [output appendString:@"+"];
        } else if (thisChar == '.' || thisChar == '-' || thisChar == '_' || thisChar == '~' ||
                   (thisChar >= 'a' && thisChar <= 'z') ||
                   (thisChar >= 'A' && thisChar <= 'Z') ||
                   (thisChar >= '0' && thisChar <= '9')) {
            [output appendFormat:@"%c", thisChar];
        } else {
            [output appendFormat:@"%%%02X", thisChar];
        }
    }
    return output;
}
@end
