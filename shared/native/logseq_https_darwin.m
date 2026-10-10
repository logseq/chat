#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>

static const NSTimeInterval LogseqRequestTimeout = 30.0;

static NSString *LogseqString(value input) {
  return [NSString stringWithUTF8String:String_val(input)];
}

static value LogseqCopyResult(NSString *result) {
  const char *utf8 = [result UTF8String];
  return caml_copy_string(utf8 == NULL ? "ERROR\nInvalid UTF-8 HTTPS result" : utf8);
}

static NSString *LogseqRedactedURL(NSURL *url) {
  NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
  components.query = nil;
  NSString *value = [[components URL] absoluteString];
  return value == nil ? @"<invalid-url>" : value;
}

CAMLprim value logseq_https_send(value method, value url, value body, value token) {
  CAMLparam4(method, url, body, token);

  NSURL *requestURL = [NSURL URLWithString:LogseqString(url)];
  if (requestURL == nil) {
    NSLog(@"Logseq HTTPS invalid URL");
    CAMLreturn(caml_copy_string("ERROR\nInvalid HTTPS URL"));
  }

  NSString *methodString = LogseqString(method);
  NSString *redactedURL = LogseqRedactedURL(requestURL);
  NSLog(@"Logseq HTTPS request started: %@ %@", methodString, redactedURL);

  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requestURL];
  [request setHTTPMethod:methodString];
  [request setTimeoutInterval:LogseqRequestTimeout];
  [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  [request setValue:[@"Bearer " stringByAppendingString:LogseqString(token)]
      forHTTPHeaderField:@"Authorization"];

  NSString *bodyString = LogseqString(body);
  if ([bodyString length] > 0) {
    [request setHTTPBody:[bodyString dataUsingEncoding:NSUTF8StringEncoding]];
  }

  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
  __block NSData *responseData = nil;
  __block NSURLResponse *urlResponse = nil;
  __block NSError *requestError = nil;

  NSURLSessionDataTask *task = [[NSURLSession sharedSession]
      dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
          responseData = data;
          urlResponse = response;
          requestError = error;
          dispatch_semaphore_signal(semaphore);
        }];
  [task resume];

  dispatch_time_t timeout =
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(LogseqRequestTimeout * NSEC_PER_SEC));
  caml_enter_blocking_section();
  long waitResult = dispatch_semaphore_wait(semaphore, timeout);
  caml_leave_blocking_section();
  if (waitResult != 0) {
    [task cancel];
    NSLog(@"Logseq HTTPS request timed out after %.0fs: %@ %@",
          LogseqRequestTimeout, methodString, redactedURL);
    CAMLreturn(caml_copy_string("ERROR\nHTTPS request timed out after 30s"));
  }

  if (requestError != nil) {
    NSLog(@"Logseq HTTPS request failed: %@ %@ %@ %ld %@", methodString, redactedURL,
          [requestError domain], (long)[requestError code], [requestError localizedDescription]);
    NSString *message = [@"ERROR\n" stringByAppendingString:[requestError localizedDescription]];
    CAMLreturn(LogseqCopyResult(message));
  }

  if (![urlResponse isKindOfClass:[NSHTTPURLResponse class]]) {
    NSLog(@"Logseq HTTPS response was not HTTP: %@ %@", methodString, redactedURL);
    CAMLreturn(caml_copy_string("ERROR\nHTTPS response was not HTTP"));
  }

  NSInteger status = [(NSHTTPURLResponse *)urlResponse statusCode];
  NSString *responseBody =
      [[NSString alloc] initWithData:(responseData ?: [NSData data])
                            encoding:NSUTF8StringEncoding];
  if (responseBody == nil) {
    responseBody = @"";
  }

  NSLog(@"Logseq HTTPS request finished: %@ %@ status=%ld bytes=%lu",
        methodString, redactedURL, (long)status, (unsigned long)[responseData length]);

  NSString *result = [NSString stringWithFormat:@"%ld\n%@", (long)status, responseBody];
  CAMLreturn(LogseqCopyResult(result));
}

CAMLprim value logseq_https_upload_file(value method, value url, value file_path,
                                              value content_type, value token) {
  CAMLparam5(method, url, file_path, content_type, token);

  NSURL *requestURL = [NSURL URLWithString:LogseqString(url)];
  NSURL *fileURL = [NSURL fileURLWithPath:LogseqString(file_path)];
  if (requestURL == nil || ![[NSFileManager defaultManager] fileExistsAtPath:[fileURL path]]) {
    CAMLreturn(caml_copy_string("ERROR\nInvalid upload URL or missing local file"));
  }

  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requestURL];
  [request setHTTPMethod:LogseqString(method)];
  [request setTimeoutInterval:LogseqRequestTimeout];
  [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  [request setValue:LogseqString(content_type) forHTTPHeaderField:@"Content-Type"];
  [request setValue:[@"Bearer " stringByAppendingString:LogseqString(token)]
      forHTTPHeaderField:@"Authorization"];

  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
  __block NSData *responseData = nil;
  __block NSURLResponse *urlResponse = nil;
  __block NSError *requestError = nil;
  NSURLSessionUploadTask *task = [[NSURLSession sharedSession]
      uploadTaskWithRequest:request
                  fromFile:fileURL
         completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
           responseData = data;
           urlResponse = response;
           requestError = error;
           dispatch_semaphore_signal(semaphore);
         }];
  [task resume];

  dispatch_time_t timeout =
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(LogseqRequestTimeout * NSEC_PER_SEC));
  caml_enter_blocking_section();
  long waitResult = dispatch_semaphore_wait(semaphore, timeout);
  caml_leave_blocking_section();
  if (waitResult != 0) {
    [task cancel];
    CAMLreturn(caml_copy_string("ERROR\nHTTPS upload timed out after 30s"));
  }
  if (requestError != nil) {
    NSString *message = [@"ERROR\n" stringByAppendingString:[requestError localizedDescription]];
    CAMLreturn(LogseqCopyResult(message));
  }
  if (![urlResponse isKindOfClass:[NSHTTPURLResponse class]]) {
    CAMLreturn(caml_copy_string("ERROR\nHTTPS upload response was not HTTP"));
  }

  NSInteger status = [(NSHTTPURLResponse *)urlResponse statusCode];
  NSString *body = [[NSString alloc] initWithData:(responseData ?: [NSData data])
                                         encoding:NSUTF8StringEncoding] ?: @"";
  CAMLreturn(LogseqCopyResult([NSString stringWithFormat:@"%ld\n%@", (long)status, body]));
}
