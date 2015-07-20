// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#include "bin/secure_socket.h"

#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <stdio.h>
#include <string.h>

#include <openssl/bio.h>
#include <openssl/err.h>
#include <openssl/safestack.h>
#include <openssl/ssl.h>
#include <openssl/tls1.h>
#include <openssl/x509.h>

#include "bin/builtin.h"
#include "bin/dartutils.h"
#include "bin/lockers.h"
#include "bin/log.h"
#include "bin/socket.h"
#include "bin/thread.h"
#include "bin/utils.h"
#include "platform/utils.h"

#include "include/dart_api.h"

namespace dart {
namespace bin {

bool SSLFilter::library_initialized_ = false;
// To protect library initialization.
Mutex* SSLFilter::mutex_ = new Mutex();
int SSLFilter::filter_ssl_index;

static const int kSSLFilterNativeFieldIndex = 0;
static const int kSecurityContextNativeFieldIndex = 0;
static const int kX509NativeFieldIndex = 0;

static const bool SSL_LOG_STATUS = false;
static const bool SSL_LOG_DATA = false;


/* Handle an error reported from the BoringSSL ssl library. */
static void ThrowIOException(const char* exception_type,
                             const char* message,
                             bool free_message = false) {
  // TODO(whesse): Get the error code and message from the error stack.
  // There may be more than one error on the stack - should we
  // concatenate the error messages?
  int error_code = 0;
  const char* error_message = "Unknown error from BoringSSL library";
  OSError os_error_struct(error_code, error_message, OSError::kBoringSSL);
  Dart_Handle os_error = DartUtils::NewDartOSError(&os_error_struct);
  Dart_Handle exception =
      DartUtils::NewDartIOException(exception_type, message, os_error);
  if (free_message) {
    free(const_cast<char*>(message));
  }
  Dart_ThrowException(exception);
  UNREACHABLE();
}


static SSLFilter* GetFilter(Dart_NativeArguments args) {
  SSLFilter* filter;
  Dart_Handle dart_this = ThrowIfError(Dart_GetNativeArgument(args, 0));
  ASSERT(Dart_IsInstance(dart_this));
  ThrowIfError(Dart_GetNativeInstanceField(
      dart_this,
      kSSLFilterNativeFieldIndex,
      reinterpret_cast<intptr_t*>(&filter)));
  return filter;
}


static void SetFilter(Dart_NativeArguments args, SSLFilter* filter) {
  Dart_Handle dart_this = ThrowIfError(Dart_GetNativeArgument(args, 0));
  ASSERT(Dart_IsInstance(dart_this));
  ThrowIfError(Dart_SetNativeInstanceField(
      dart_this,
      kSSLFilterNativeFieldIndex,
      reinterpret_cast<intptr_t>(filter)));
}


static SSL_CTX* GetSecurityContext(Dart_NativeArguments args) {
  SSL_CTX* context;
  Dart_Handle dart_this = ThrowIfError(Dart_GetNativeArgument(args, 0));
  ASSERT(Dart_IsInstance(dart_this));
  ThrowIfError(Dart_GetNativeInstanceField(
      dart_this,
      kSecurityContextNativeFieldIndex,
      reinterpret_cast<intptr_t*>(&context)));
  return context;
}


static void SetSecurityContext(Dart_NativeArguments args,
                               SSL_CTX* context) {
  Dart_Handle dart_this = ThrowIfError(Dart_GetNativeArgument(args, 0));
  ASSERT(Dart_IsInstance(dart_this));
  ThrowIfError(Dart_SetNativeInstanceField(
      dart_this,
      kSecurityContextNativeFieldIndex,
      reinterpret_cast<intptr_t>(context)));
}


static X509* GetX509(Dart_NativeArguments args) {
  X509* certificate;
  Dart_Handle dart_this = ThrowIfError(Dart_GetNativeArgument(args, 0));
  ASSERT(Dart_IsInstance(dart_this));
  ThrowIfError(Dart_GetNativeInstanceField(
      dart_this,
      kX509NativeFieldIndex,
      reinterpret_cast<intptr_t*>(&certificate)));
  return certificate;
}


// Forward declaration.
static void SetAlpnProtocolList(Dart_Handle protocols_handle,
                                SSL* ssl,
                                SSL_CTX* context,
                                bool is_server);


void FUNCTION_NAME(SecureSocket_Init)(Dart_NativeArguments args) {
  Dart_Handle dart_this = ThrowIfError(Dart_GetNativeArgument(args, 0));
  SSLFilter* filter = new SSLFilter;
  SetFilter(args, filter);
  filter->Init(dart_this);
}


void FUNCTION_NAME(SecureSocket_Connect)(Dart_NativeArguments args) {
  Dart_Handle host_name_object = ThrowIfError(Dart_GetNativeArgument(args, 1));
  Dart_Handle host_sockaddr_storage_object =
      ThrowIfError(Dart_GetNativeArgument(args, 2));
  Dart_Handle port_object = ThrowIfError(Dart_GetNativeArgument(args, 3));
  Dart_Handle context_object = ThrowIfError(Dart_GetNativeArgument(args, 4));
  bool is_server = DartUtils::GetBooleanValue(Dart_GetNativeArgument(args, 5));
  bool request_client_certificate =
      DartUtils::GetBooleanValue(Dart_GetNativeArgument(args, 6));
  bool require_client_certificate =
      DartUtils::GetBooleanValue(Dart_GetNativeArgument(args, 7));
  bool send_client_certificate =
      DartUtils::GetBooleanValue(Dart_GetNativeArgument(args, 8));
  Dart_Handle protocols_handle =
      ThrowIfError(Dart_GetNativeArgument(args, 9));

  const char* host_name = NULL;
  // TODO(whesse): Is truncating a Dart string containing \0 what we want?
  ThrowIfError(Dart_StringToCString(host_name_object, &host_name));

  RawAddr raw_addr;
  SocketAddress::GetSockAddr(host_sockaddr_storage_object, &raw_addr);

  SSL_CTX* context = NULL;
  if (!Dart_IsNull(context_object)) {
    ThrowIfError(Dart_GetNativeInstanceField(
        context_object,
        kSecurityContextNativeFieldIndex,
        reinterpret_cast<intptr_t*>(&context)));
  }


  int64_t port;
  if (!DartUtils::GetInt64Value(port_object, &port)) {
    FATAL("The range of port_object was checked in Dart - it cannot fail here");
  }

  // The protocols_handle is guaranteed to be a valid Uint8List.
  // It will have the correct length encoding of the protocols array.
  ASSERT(!Dart_IsNull(protocols_handle));

  GetFilter(args)->Connect(host_name,
                           raw_addr,
                           static_cast<int>(port),
                           context,
                           is_server,
                           request_client_certificate,
                           require_client_certificate,
                           send_client_certificate,
                           protocols_handle);
}


void FUNCTION_NAME(SecureSocket_Destroy)(Dart_NativeArguments args) {
  SSLFilter* filter = GetFilter(args);
  SetFilter(args, NULL);
  filter->Destroy();
  delete filter;
}


void FUNCTION_NAME(SecureSocket_Handshake)(Dart_NativeArguments args) {
  GetFilter(args)->Handshake();
}


void FUNCTION_NAME(SecureSocket_GetSelectedProtocol)(
    Dart_NativeArguments args) {
  GetFilter(args)->GetSelectedProtocol(args);
}


void FUNCTION_NAME(SecureSocket_Renegotiate)(Dart_NativeArguments args) {
  bool use_session_cache =
      DartUtils::GetBooleanValue(Dart_GetNativeArgument(args, 1));
  bool request_client_certificate =
      DartUtils::GetBooleanValue(Dart_GetNativeArgument(args, 2));
  bool require_client_certificate =
      DartUtils::GetBooleanValue(Dart_GetNativeArgument(args, 3));
  GetFilter(args)->Renegotiate(use_session_cache,
                               request_client_certificate,
                               require_client_certificate);
}


void FUNCTION_NAME(SecureSocket_RegisterHandshakeCompleteCallback)(
    Dart_NativeArguments args) {
  Dart_Handle handshake_complete =
      ThrowIfError(Dart_GetNativeArgument(args, 1));
  if (!Dart_IsClosure(handshake_complete)) {
    Dart_ThrowException(DartUtils::NewDartArgumentError(
        "Illegal argument to RegisterHandshakeCompleteCallback"));
  }
  GetFilter(args)->RegisterHandshakeCompleteCallback(handshake_complete);
}


void FUNCTION_NAME(SecureSocket_RegisterBadCertificateCallback)(
    Dart_NativeArguments args) {
  Dart_Handle callback =
      ThrowIfError(Dart_GetNativeArgument(args, 1));
  if (!Dart_IsClosure(callback) && !Dart_IsNull(callback)) {
    Dart_ThrowException(DartUtils::NewDartArgumentError(
        "Illegal argument to RegisterBadCertificateCallback"));
  }
  GetFilter(args)->RegisterBadCertificateCallback(callback);
}


void FUNCTION_NAME(SecureSocket_PeerCertificate)
    (Dart_NativeArguments args) {
  Dart_SetReturnValue(args, GetFilter(args)->PeerCertificate());
}


void FUNCTION_NAME(SecureSocket_FilterPointer)(Dart_NativeArguments args) {
  intptr_t filter_pointer = reinterpret_cast<intptr_t>(GetFilter(args));
  Dart_SetReturnValue(args, Dart_NewInteger(filter_pointer));
}

// Forward declaration
static Dart_Handle WrappedX509(X509* certificate);

int CertificateCallback(int preverify_ok, X509_STORE_CTX* store_ctx) {
  if (preverify_ok == 1) return 1;
  Dart_Isolate isolate = Dart_CurrentIsolate();
  if (isolate == NULL) {
    FATAL("CertificateCallback called with no current isolate\n");
  }
  X509* certificate = X509_STORE_CTX_get_current_cert(store_ctx);
  int ssl_index = SSL_get_ex_data_X509_STORE_CTX_idx();
  SSL* ssl = static_cast<SSL*>(
      X509_STORE_CTX_get_ex_data(store_ctx, ssl_index));
  SSLFilter* filter = static_cast<SSLFilter*>(
      SSL_get_ex_data(ssl, SSLFilter::filter_ssl_index));
  Dart_Handle callback = filter->bad_certificate_callback();
  if (Dart_IsNull(callback)) return 0;
  Dart_Handle args[1];
  args[0] = WrappedX509(certificate);
  Dart_Handle result = Dart_InvokeClosure(callback, 1, args);
  if (!Dart_IsError(result) && !Dart_IsBoolean(result)) {
    result = Dart_NewUnhandledExceptionError(DartUtils::NewDartIOException(
        "HandshakeException",
        "BadCertificateCallback returned a value that was not a boolean",
        Dart_Null()));
  }
  if (Dart_IsError(result)) {
    filter->callback_error = result;
    return 0;
  }
  return DartUtils::GetBooleanValue(result);
}


void FUNCTION_NAME(SecurityContext_Allocate)(Dart_NativeArguments args) {
  SSLFilter::InitializeLibrary();
  SSL_CTX* context = SSL_CTX_new(TLS_method());
  SSL_CTX_set_verify(context, SSL_VERIFY_PEER, CertificateCallback);
  SSL_CTX_set_min_version(context, TLS1_VERSION);
  SSL_CTX_set_cipher_list(context, "HIGH:MEDIUM");
  SSL_CTX_set_cipher_list_tls11(context, "HIGH:MEDIUM");
  SetSecurityContext(args, context);
  // TODO(whesse): Use WeakPersistentHandle to free the SSL_CTX
  // when the object is GC'd.  Also free the alpn_select_cb data pointer,
  // if non-null (allocated in SetAlpnProtocolList).
}


int PasswordCallback(char* buf, int size, int rwflag, void* userdata) {
  if (SSL_LOG_STATUS) Log::Print(
      "PasswordCallback called: size %d rwflag %d password %s\n",
      size, rwflag, static_cast<char*>(userdata));
  if (userdata == NULL) {
    userdata = static_cast<void*>(const_cast<char*>("dartdart"));
  }
  // if (size < strlen(userdata) + 1)
  if (size < 9) {
    Log::PrintErr("Password buffer too small.\n");
    exit(1);
  }
  strncpy(buf, static_cast<char*>(userdata), size);
  return strlen(static_cast<char*>(userdata));
}


void CheckStatus(int status, const char* message, int line) {
  if (status != 1) {
    int error = ERR_get_error();
    Log::PrintErr("Failed: %s line %d\n", message, line);
    char error_string[101];
    ERR_error_string_n(error, error_string, 100);
    Log::PrintErr("ERROR: %d %s\n", error, error_string);
  }
}


void FUNCTION_NAME(SecurityContext_UsePrivateKey)(Dart_NativeArguments args) {
  SSL_CTX* context = GetSecurityContext(args);
  Dart_Handle filename_object = ThrowIfError(Dart_GetNativeArgument(args, 1));
  // Check that the type is string or null,
  // and get the UTF-8 C string value from it.
  const char* filename = NULL;
  if (Dart_IsString(filename_object)) {
    ThrowIfError(Dart_StringToCString(filename_object, &filename));
  } else {
    Dart_ThrowException(DartUtils::NewDartArgumentError(
        "File argument to SecurityContext.usePrivateKey is not a String"));
  }
  Dart_Handle password_object = ThrowIfError(Dart_GetNativeArgument(args, 2));
  // Check that the type is string or null,
  // and get the UTF-8 C string value from it.
  const char* password = NULL;
  if (Dart_IsString(password_object)) {
    ThrowIfError(Dart_StringToCString(password_object, &password));
  } else if (Dart_IsNull(password_object)) {
    // Pass the empty string as the password.
    password = "";
  } else {
    Dart_ThrowException(DartUtils::NewDartArgumentError(
        "Password argument to SecurityContext.usePrivateKey is not "
        "a String or null"));
  }

  SSL_CTX_set_default_passwd_cb(context, PasswordCallback);
  SSL_CTX_set_default_passwd_cb_userdata(context, const_cast<char*>(password));
  int status = SSL_CTX_use_PrivateKey_file(context,
                                           filename,
                                           SSL_FILETYPE_PEM);
  CheckStatus(status, "SSL_CTX_use_PrivateKey_file", __LINE__);
  SSL_CTX_set_default_passwd_cb_userdata(context, NULL);
}


void FUNCTION_NAME(SecurityContext_SetTrustedCertificates)(
    Dart_NativeArguments args) {
  SSL_CTX* context = GetSecurityContext(args);
  Dart_Handle filename_object = ThrowIfError(Dart_GetNativeArgument(args, 1));
  // Check that the type is string or null,
  // and get the UTF-8 C string value from it.
  const char* filename = NULL;
  if (Dart_IsString(filename_object)) {
    ThrowIfError(Dart_StringToCString(filename_object, &filename));
  }
  Dart_Handle directory_object = ThrowIfError(Dart_GetNativeArgument(args, 2));
  // Check that the type is string or null,
  // and get the UTF-8 C string value from it.
  const char* directory = NULL;
  if (Dart_IsString(directory_object)) {
    ThrowIfError(Dart_StringToCString(directory_object, &directory));
  } else if (Dart_IsNull(directory_object)) {
    // Pass the empty string as the directory.
    directory = NULL;
  } else {
    Dart_ThrowException(DartUtils::NewDartArgumentError(
        "Directory argument to SecurityContext.usePrivateKey is not "
        "a String or null"));
  }

  int status = SSL_CTX_load_verify_locations(context, filename, directory);
  CheckStatus(status, "SSL_CTX_load_verify_locations", __LINE__);
}


void FUNCTION_NAME(SecurityContext_TrustBuiltinRoots)(
    Dart_NativeArguments args) {
  SSL_CTX* context = GetSecurityContext(args);
  X509_STORE* store = SSL_CTX_get_cert_store(context);
  BIO* roots_bio =
      BIO_new_mem_buf(const_cast<unsigned char*>(root_certificates_pem),
                      root_certificates_pem_length);
  X509* root_cert;
  while ((root_cert = PEM_read_bio_X509(roots_bio, NULL, NULL, NULL))) {
    X509_STORE_add_cert(store, root_cert);
  }
  BIO_free(roots_bio);
}


void FUNCTION_NAME(SecurityContext_UseCertificateChain)(
    Dart_NativeArguments args) {
  SSL_CTX* context = GetSecurityContext(args);
  Dart_Handle filename_object = ThrowIfError(Dart_GetNativeArgument(args, 1));
  const char* filename = NULL;
  if (Dart_IsString(filename_object)) {
    ThrowIfError(Dart_StringToCString(filename_object, &filename));
  }
  int status = SSL_CTX_use_certificate_chain_file(context, filename);
  CheckStatus(status, "SSL_CTX_use_certificate_chain_file", __LINE__);
}


void FUNCTION_NAME(SecurityContext_SetClientAuthorities)(
    Dart_NativeArguments args) {
  SSL_CTX* context = GetSecurityContext(args);
  Dart_Handle filename_object = ThrowIfError(Dart_GetNativeArgument(args, 1));
  const char* filename = NULL;
  if (Dart_IsString(filename_object)) {
    ThrowIfError(Dart_StringToCString(filename_object, &filename));
  }
  STACK_OF(X509_NAME)* certificate_names;
  certificate_names = SSL_load_client_CA_file(filename);
  if (certificate_names != NULL) {
    SSL_CTX_set_client_CA_list(context, certificate_names);
  } else {
    Dart_ThrowException(DartUtils::NewDartArgumentError(
        "Could not load certificate names from file in SetClientAuthorities"));
  }
}


void FUNCTION_NAME(SecurityContext_SetAlpnProtocols)(
    Dart_NativeArguments args) {
  SSL_CTX* context = GetSecurityContext(args);
  Dart_Handle protocols_handle =
      ThrowIfError(Dart_GetNativeArgument(args, 1));
  Dart_Handle is_server_handle =
      ThrowIfError(Dart_GetNativeArgument(args, 2));
  if (Dart_IsBoolean(is_server_handle)) {
    bool is_server = DartUtils::GetBooleanValue(is_server_handle);
    SetAlpnProtocolList(protocols_handle, NULL, context, is_server);
  } else {
    Dart_ThrowException(DartUtils::NewDartArgumentError(
        "Non-boolean is_server argument passed to SetAlpnProtocols"));
  }
}


void FUNCTION_NAME(X509_Subject)(
    Dart_NativeArguments args) {
  X509* certificate = GetX509(args);
  X509_NAME* subject = X509_get_subject_name(certificate);
  char* subject_string = X509_NAME_oneline(subject, NULL, 1000);
  Dart_SetReturnValue(args, Dart_NewStringFromCString(subject_string));
}


void FUNCTION_NAME(X509_Issuer)(
    Dart_NativeArguments args) {
  X509* certificate = GetX509(args);
  X509_NAME* issuer = X509_get_issuer_name(certificate);
  char* issuer_string = X509_NAME_oneline(issuer, NULL, 1000);
  Dart_SetReturnValue(args, Dart_NewStringFromCString(issuer_string));
}

static Dart_Handle ASN1TimeToMilliseconds(ASN1_TIME* aTime) {
  ASN1_UTCTIME* epochStart = M_ASN1_UTCTIME_new();
  ASN1_UTCTIME_set_string(epochStart, "700101000000Z");
  int days;
  int seconds;
  int result = ASN1_TIME_diff(&days, &seconds, epochStart, aTime);
  if (result != 1) {
    // signal an error;
    Log::PrintErr("ASN1Time error %d\n", result);
  }
  return Dart_NewInteger((86400LL * days + seconds) * 1000LL);
}

void FUNCTION_NAME(X509_StartValidity)(
    Dart_NativeArguments args) {
  X509* certificate = GetX509(args);
  ASN1_TIME* not_before = X509_get_notBefore(certificate);
  Dart_SetReturnValue(args, ASN1TimeToMilliseconds(not_before));
}


void FUNCTION_NAME(X509_EndValidity)(
    Dart_NativeArguments args) {
  X509* certificate = GetX509(args);
  ASN1_TIME* not_after = X509_get_notAfter(certificate);
  Dart_SetReturnValue(args, ASN1TimeToMilliseconds(not_after));
}


/**
 * Pushes data through the SSL filter, reading and writing from circular
 * buffers shared with Dart.
 *
 * The Dart _SecureFilterImpl class contains 4 ExternalByteArrays used to
 * pass encrypted and plaintext data to and from the C++ SSLFilter object.
 *
 * ProcessFilter is called with a CObject array containing the pointer to
 * the SSLFilter, encoded as an int, and the start and end positions of the
 * valid data in the four circular buffers.  The function only reads from
 * the valid data area of the input buffers, and only writes to the free
 * area of the output buffers.  The function returns the new start and end
 * positions in the buffers, but it only updates start for input buffers, and
 * end for output buffers.  Therefore, the Dart thread can simultaneously
 * write to the free space and end pointer of input buffers, and read from
 * the data space of output buffers, and modify the start pointer.
 *
 * When ProcessFilter returns, the Dart thread is responsible for combining
 * the updated pointers from Dart and C++, to make the new valid state of
 * the circular buffer.
 */
CObject* SSLFilter::ProcessFilterRequest(const CObjectArray& request) {
  CObjectIntptr filter_object(request[0]);
  SSLFilter* filter = reinterpret_cast<SSLFilter*>(filter_object.Value());
  bool in_handshake = CObjectBool(request[1]).Value();
  int starts[SSLFilter::kNumBuffers];
  int ends[SSLFilter::kNumBuffers];
  for (int i = 0; i < SSLFilter::kNumBuffers; ++i) {
    starts[i] = CObjectInt32(request[2 * i + 2]).Value();
    ends[i] = CObjectInt32(request[2 * i + 3]).Value();
  }

  if (filter->ProcessAllBuffers(starts, ends, in_handshake)) {
    CObjectArray* result = new CObjectArray(
        CObject::NewArray(SSLFilter::kNumBuffers * 2));
    for (int i = 0; i < SSLFilter::kNumBuffers; ++i) {
      result->SetAt(2 * i, new CObjectInt32(CObject::NewInt32(starts[i])));
      result->SetAt(2 * i + 1, new CObjectInt32(CObject::NewInt32(ends[i])));
    }
    return result;
  } else {
    // TODO(whesse): Extract the BoringSSL OS error here and return it.
    int error_code = 1;
    const char* error_message = "Obsolete PR Error message";
    CObjectArray* result = new CObjectArray(CObject::NewArray(2));
    result->SetAt(0, new CObjectInt32(CObject::NewInt32(error_code)));
    result->SetAt(1, new CObjectString(CObject::NewString(error_message)));
    return result;
  }
}


bool SSLFilter::ProcessAllBuffers(int starts[kNumBuffers],
                                  int ends[kNumBuffers],
                                  bool in_handshake) {
  for (int i = 0; i < kNumBuffers; ++i) {
    if (in_handshake && (i == kReadPlaintext || i == kWritePlaintext)) continue;
    int start = starts[i];
    int end = ends[i];
    int size = isBufferEncrypted(i) ? encrypted_buffer_size_ : buffer_size_;
    if (start < 0 || end < 0 || start >= size || end >= size) {
      FATAL("Out-of-bounds internal buffer access in dart:io SecureSocket");
    }
    switch (i) {
      case kReadPlaintext:
      case kWriteEncrypted:
        // Write data to the circular buffer's free space.  If the buffer
        // is full, neither if statement is executed and nothing happens.
        if (start <= end) {
          // If the free space may be split into two segments,
          // then the first is [end, size), unless start == 0.
          // Then, since the last free byte is at position start - 2,
          // the interval is [end, size - 1).
          int buffer_end = (start == 0) ? size - 1 : size;
          int bytes = (i == kReadPlaintext) ?
              ProcessReadPlaintextBuffer(end, buffer_end) :
              ProcessWriteEncryptedBuffer(end, buffer_end);
          if (bytes < 0) return false;
          end += bytes;
          ASSERT(end <= size);
          if (end == size) end = 0;
        }
        if (start > end + 1) {
          int bytes =  (i == kReadPlaintext) ?
              ProcessReadPlaintextBuffer(end, start - 1) :
              ProcessWriteEncryptedBuffer(end, start - 1);
          if (bytes < 0) return false;
          end += bytes;
          ASSERT(end < start);
        }
        ends[i] = end;
        break;
      case kReadEncrypted:
        // Read data from circular buffer.
        if (end < start) {
          // Data may be split into two segments.  In this case,
          // the first is [start, size).
          int bytes = ProcessReadEncryptedBuffer(start, size);
          if (bytes < 0) return false;
          start += bytes;
          ASSERT(start <= size);
          if (start == size) start = 0;
        }
        if (start < end) {
          int bytes = ProcessReadEncryptedBuffer(start, end);
          if (bytes < 0) return false;
          start += bytes;
          ASSERT(start <= end);
        }
        starts[i] = start;
        break;
      case kWritePlaintext:
        if (end < start) {
          // Data is split into two segments, [start, size) and [0, end).
          int bytes = ProcessWritePlaintextBuffer(start, size, 0, end);
          if (bytes < 0) return false;
          start += bytes;
          if (start >= size) start -= size;
        } else {
          int bytes = ProcessWritePlaintextBuffer(start, end, 0, 0);
          if (bytes < 0) return false;
          start += bytes;
          ASSERT(start <= end);
        }
        starts[i] = start;
        break;
      default:
        UNREACHABLE();
    }
  }
  return true;
}


static Dart_Handle WrappedX509(X509* certificate) {
  if (certificate == NULL) return Dart_Null();
  Dart_Handle x509_type =
      DartUtils::GetDartType(DartUtils::kIOLibURL, "X509Certificate");
  Dart_Handle arguments[] = { NULL };
  if (Dart_IsError(x509_type)) {
    Dart_PropagateError(x509_type);
  }
  Dart_Handle result =
      Dart_New(x509_type, DartUtils::NewString("_"), 0, arguments);
  if (Dart_IsError(result)) {
    Dart_PropagateError(result);
  }
  ASSERT(Dart_IsInstance(result));
  ThrowIfError(Dart_SetNativeInstanceField(
      result,
      kX509NativeFieldIndex,
      reinterpret_cast<intptr_t>(certificate)));
  return result;
}


void SSLFilter::Init(Dart_Handle dart_this) {
  if (!library_initialized_) {
    InitializeLibrary();
  }
  ASSERT(string_start_ == NULL);
  string_start_ = Dart_NewPersistentHandle(DartUtils::NewString("start"));
  ASSERT(string_start_ != NULL);
  ASSERT(string_length_ == NULL);
  string_length_ = Dart_NewPersistentHandle(DartUtils::NewString("length"));
  ASSERT(string_length_ != NULL);
  ASSERT(bad_certificate_callback_ == NULL);
  bad_certificate_callback_ = Dart_NewPersistentHandle(Dart_Null());
  ASSERT(bad_certificate_callback_ != NULL);

  InitializeBuffers(dart_this);
}


void SSLFilter::InitializeBuffers(Dart_Handle dart_this) {
  // Create SSLFilter buffers as ExternalUint8Array objects.
  Dart_Handle dart_buffers_object = ThrowIfError(
      Dart_GetField(dart_this, DartUtils::NewString("buffers")));
  Dart_Handle secure_filter_impl_type =
      Dart_InstanceGetType(dart_this);
  Dart_Handle dart_buffer_size = ThrowIfError(
      Dart_GetField(secure_filter_impl_type, DartUtils::NewString("SIZE")));
  int64_t buffer_size = DartUtils::GetIntegerValue(dart_buffer_size);
  Dart_Handle dart_encrypted_buffer_size = ThrowIfError(
      Dart_GetField(secure_filter_impl_type,
                    DartUtils::NewString("ENCRYPTED_SIZE")));
  int64_t encrypted_buffer_size =
      DartUtils::GetIntegerValue(dart_encrypted_buffer_size);
  if (buffer_size <= 0 || buffer_size > 1 * MB) {
    FATAL("Invalid buffer size in _ExternalBuffer");
  }
  if (encrypted_buffer_size <= 0 || encrypted_buffer_size > 1 * MB) {
    FATAL("Invalid encrypted buffer size in _ExternalBuffer");
  }
  buffer_size_ = static_cast<int>(buffer_size);
  encrypted_buffer_size_ = static_cast<int>(encrypted_buffer_size);


  Dart_Handle data_identifier = DartUtils::NewString("data");
  for (int i = 0; i < kNumBuffers; ++i) {
    int size = isBufferEncrypted(i) ? encrypted_buffer_size_ : buffer_size_;
    dart_buffer_objects_[i] =
        Dart_NewPersistentHandle(Dart_ListGetAt(dart_buffers_object, i));
    ASSERT(dart_buffer_objects_[i] != NULL);
    buffers_[i] = new uint8_t[size];
    Dart_Handle data = ThrowIfError(
        Dart_NewExternalTypedData(Dart_TypedData_kUint8, buffers_[i], size));
    ThrowIfError(
        Dart_SetField(Dart_HandleFromPersistent(dart_buffer_objects_[i]),
                      data_identifier,
                      data));
  }
}


void SSLFilter::RegisterHandshakeCompleteCallback(Dart_Handle complete) {
  ASSERT(NULL == handshake_complete_);
  handshake_complete_ = Dart_NewPersistentHandle(complete);

  ASSERT(handshake_complete_ != NULL);
}


void SSLFilter::RegisterBadCertificateCallback(Dart_Handle callback) {
  ASSERT(bad_certificate_callback_ != NULL);
  Dart_DeletePersistentHandle(bad_certificate_callback_);
  bad_certificate_callback_ = Dart_NewPersistentHandle(callback);
  ASSERT(bad_certificate_callback_ != NULL);
}


void SSLFilter::InitializeLibrary() {
  MutexLocker locker(mutex_);
  if (!library_initialized_) {
    SSL_library_init();
    filter_ssl_index = SSL_get_ex_new_index(0, NULL, NULL, NULL, NULL);
    ASSERT(filter_ssl_index >= 0);
    library_initialized_ = true;
  }
}


Dart_Handle SSLFilter::PeerCertificate() {
  // Get peer certificate X509 object, pass it to
  X509* certificate = SSL_get_peer_certificate(ssl_);
  Dart_Handle x509_object = WrappedX509(certificate);
  return x509_object;
}


int AlpnCallback(SSL *ssl,
                 const uint8_t **out,
                 uint8_t *outlen,
                 const uint8_t *in,
                 unsigned int inlen,
                 void *arg) {
  // 'in' and 'arg' are sequences of (length, data) strings with 1-byte lengths.
  // 'arg' is 0-terminated. Finds the first string in 'arg' that is in 'in'.
  uint8_t* server_list = static_cast<uint8_t*>(arg);
  while (*server_list != 0) {
    uint8_t protocol_length = *server_list++;
    const uint8_t* client_list = in;
    while (client_list < in + inlen) {
      uint8_t client_protocol_length = *client_list++;
      if (client_protocol_length == protocol_length) {
        if (0 == memcmp(server_list, client_list, protocol_length)) {
          *out = client_list;
          *outlen = client_protocol_length;
          return SSL_TLSEXT_ERR_OK;  // Success
        }
      }
      client_list += client_protocol_length;
    }
    server_list += protocol_length;
  }
  // TODO(23580): Make failure send a fatal alert instead of ignoring ALPN.
  return SSL_TLSEXT_ERR_NOACK;
}


// Sets the protocol list for ALPN on a SSL object or a context.
static void SetAlpnProtocolList(Dart_Handle protocols_handle,
                                SSL* ssl,
                                SSL_CTX* context,
                                bool is_server) {
  // Enable ALPN (application layer protocol negotiation) if the caller provides
  // a valid list of supported protocols.
  Dart_TypedData_Type protocols_type;
  uint8_t* protocol_string = NULL;
  uint8_t* protocol_string_copy = NULL;
  intptr_t protocol_string_len = 0;
  int status;

  Dart_Handle result = Dart_TypedDataAcquireData(
      protocols_handle,
      &protocols_type,
      reinterpret_cast<void**>(&protocol_string),
      &protocol_string_len);
  if (Dart_IsError(result)) {
    Dart_PropagateError(result);
  }

  if (protocols_type != Dart_TypedData_kUint8) {
    Dart_TypedDataReleaseData(protocols_handle);
    Dart_PropagateError(Dart_NewApiError(
        "Unexpected type for protocols (expected valid Uint8List)."));
  }

  if (protocol_string_len > 0) {
    if (is_server) {
      // ALPN on server connections must be set on an SSL_CTX object,
      // not on the SSL object of the individual connection.
      ASSERT(context != NULL);
      ASSERT(ssl == NULL);
      // Because it must be passed as a single void*, terminate
      // the list of (length, data) strings with a length 0 string.
      protocol_string_copy =
          static_cast<uint8_t*>(malloc(protocol_string_len + 1));
      memmove(protocol_string_copy, protocol_string, protocol_string_len);
      protocol_string_copy[protocol_string_len] = '\0';
      SSL_CTX_set_alpn_select_cb(context, AlpnCallback, protocol_string_copy);
      // TODO(whesse): If this function is called again, free the previous
      // protocol_string_copy.  It may be better to keep this as a native
      // field on the Dart object, since fetching it from the structure is
      // not in the public api.  Also free this when the context is destroyed.
    } else {
      // The function makes a local copy of protocol_string, which it owns.
      if (ssl != NULL) {
        ASSERT(context == NULL);
        status = SSL_set_alpn_protos(ssl, protocol_string, protocol_string_len);
      } else {
        ASSERT(context != NULL);
        ASSERT(ssl == NULL);
        status = SSL_CTX_set_alpn_protos(
            context, protocol_string, protocol_string_len);
      }
      ASSERT(status == 0);  // The function returns a non-standard status.
    }
  }
  Dart_TypedDataReleaseData(protocols_handle);
}


void SSLFilter::Connect(const char* hostname,
                        const RawAddr& raw_addr,
                        int port,
                        SSL_CTX* context,
                        bool is_server,
                        bool request_client_certificate,
                        bool require_client_certificate,
                        bool send_client_certificate,
                        Dart_Handle protocols_handle) {
  is_server_ = is_server;
  if (in_handshake_) {
    FATAL("Connect called twice on the same _SecureFilter.");
  }

  int status;
  int error;
  BIO* ssl_side;
  status = BIO_new_bio_pair(&ssl_side, 10000, &socket_side_, 10000);
  CheckStatus(status, "BIO_new_bio_pair", __LINE__);

  if (context == NULL) {
    DART_CHECK_VALID(Dart_ThrowException(DartUtils::NewDartArgumentError(
        "Default SecurityContext not implemented, context cannot be null.")));
  }

  ssl_ = SSL_new(context);
  SSL_set_bio(ssl_, ssl_side, ssl_side);
  SSL_set_mode(ssl_, SSL_MODE_AUTO_RETRY);
  SSL_set_ex_data(ssl_, filter_ssl_index, this);

  if (!is_server_) {
    SetAlpnProtocolList(protocols_handle, ssl_, NULL, false);
    certificate_checking_parameters_ = X509_VERIFY_PARAM_new();
    hostname_ = strdup(hostname);
    X509_VERIFY_PARAM_set_hostflags(certificate_checking_parameters_, 0);
    X509_VERIFY_PARAM_set1_host(certificate_checking_parameters_,
                                hostname_, strlen(hostname_));
    SSL_set1_param(ssl_, certificate_checking_parameters_);
  }
  if (is_server_) {
    status = SSL_accept(ssl_);
    if (SSL_LOG_STATUS) Log::Print("SSL_accept status: %d\n", status);
    if (status != 1) {
      error = SSL_get_error(ssl_, status);
      if (SSL_LOG_STATUS) Log::Print("SSL_accept error: %d\n", error);
    }
  } else {
    status = SSL_connect(ssl_);
    if (SSL_LOG_STATUS) Log::Print("SSL_connect status: %d\n", status);
    if (status != 1) {
      error = SSL_get_error(ssl_, status);
      if (SSL_LOG_STATUS) Log::Print("SSL_connect error: %d\n", error);
    }
  }
  if (is_server_) {
    // Set up certificate and private key
    if (request_client_certificate) {
      Dart_ThrowException(DartUtils::NewDartArgumentError(
          "requestClientCertificate not implemented."));
    }
  } else {  // Client.
    if (send_client_certificate) {
      Dart_ThrowException(DartUtils::NewDartArgumentError(
          "sendClientCertificate not implemented."));
    }
  }
  Handshake();
}


int printErrorCallback(const char *str, size_t len, void *ctx) {
  Log::PrintErr("%.*s\n", static_cast<int>(len), str);
  return 1;
}

void SSLFilter::Handshake() {
  // Try and push handshake along.
  int status;
  int error;
  status = SSL_do_handshake(ssl_);
  if (callback_error != NULL) {
    Dart_PropagateError(callback_error);
  }
  if (SSL_LOG_STATUS) Log::Print("SSL_handshake status: %d\n", status);
  if (status != 1) {
    error = SSL_get_error(ssl_, status);
    if (SSL_LOG_STATUS) Log::Print("ERROR: %d\n", error);
    ERR_print_errors_cb(printErrorCallback, NULL);
  }
  if (status == 1) {
    if (in_handshake_) {
      // TODO(whesse): Check return value of SSL_get_verify_result, this
      //    should give us the hostname check.
      int result = SSL_get_verify_result(ssl_);
      if (SSL_LOG_STATUS) {
        Log::Print("Handshake verification status: %d\n", result);
        X509* peer_certificate = SSL_get_peer_certificate(ssl_);
        if (peer_certificate == NULL) {
          Log::Print("No peer certificate received\n");
        } else {
          X509_NAME* s_name = X509_get_subject_name(peer_certificate);
          printf("Peer certificate SN: ");
          X509_NAME_print_ex_fp(stdout, s_name, 4, 0);
          printf("\n");
        }
      }
      ThrowIfError(Dart_InvokeClosure(
          Dart_HandleFromPersistent(handshake_complete_), 0, NULL));
      in_handshake_ = false;
    }
  } else if (status == 0) {
    if (is_server_) {
      ThrowIOException("HandshakeException",
                       "Handshake error in server");
    } else {
      ThrowIOException("HandshakeException",
                       "Handshake error in client");
    }
  } else if (status < 0) {
    if (SSL_want_write(ssl_) || SSL_want_read(ssl_)) {
      if (!in_handshake_) {
        in_handshake_ = true;
      }
    } else {
      if (is_server_) {
        ThrowIOException("HandshakeException",
                         "Handshake error in server");
      } else {
        ThrowIOException("HandshakeException",
                         "Handshake error in client");
      }
    }
  }
}

void SSLFilter::GetSelectedProtocol(Dart_NativeArguments args) {
  const uint8_t* protocol;
  unsigned length;
  SSL_get0_alpn_selected(ssl_, &protocol, &length);
  if (length == 0) {
    Dart_SetReturnValue(args, Dart_Null());
  } else {
    Dart_SetReturnValue(args, Dart_NewStringFromUTF8(protocol, length));
  }
}


void SSLFilter::Renegotiate(bool use_session_cache,
                            bool request_client_certificate,
                            bool require_client_certificate) {
  // The SSL_REQUIRE_CERTIFICATE option only takes effect if the
  // SSL_REQUEST_CERTIFICATE option is also set, so set it.
  request_client_certificate =
      request_client_certificate || require_client_certificate;
  // TODO(whesse): Implement setting the client certificate parameters,
  //   and triggering rehandshake.
}


void SSLFilter::Destroy() {
  for (int i = 0; i < kNumBuffers; ++i) {
    Dart_DeletePersistentHandle(dart_buffer_objects_[i]);
    delete[] buffers_[i];
  }
  Dart_DeletePersistentHandle(string_start_);
  Dart_DeletePersistentHandle(string_length_);
  Dart_DeletePersistentHandle(handshake_complete_);
  Dart_DeletePersistentHandle(bad_certificate_callback_);
  free(hostname_);
  if (certificate_checking_parameters_ != NULL) {
    X509_VERIFY_PARAM_free(certificate_checking_parameters_);
  }
}


/* Read decrypted data from the filter to the circular buffer */
intptr_t SSLFilter::ProcessReadPlaintextBuffer(int start, int end) {
  int length = end - start;
  int bytes_processed = 0;
  if (length > 0) {
    bytes_processed = SSL_read(
        ssl_,
        reinterpret_cast<char*>((buffers_[kReadPlaintext] + start)),
        length);
    if (bytes_processed < 0) {
      int error = SSL_get_error(ssl_, bytes_processed);
      USE(error);
      bytes_processed = 0;
    }
  }
  return bytes_processed;
}


intptr_t SSLFilter::ProcessWritePlaintextBuffer(int start1, int end1,
                                                int start2, int end2) {
  int length = end1 - start1;
  int x = SSL_write(ssl_, buffers_[kWritePlaintext] + start1, length);
  if (x < 0) {
    if (SSL_LOG_DATA) Log::Print("SSL_write returned error %d\n", x);
    return 0;
  }
  return x;
}


/* Read encrypted data from the circular buffer to the filter */
intptr_t SSLFilter::ProcessReadEncryptedBuffer(int start, int end) {
  int length = end - start;
  if (SSL_LOG_DATA) Log::Print(
      "Entering ProcessReadEncryptedBuffer with %d bytes\n", length);
  int bytes_processed = 0;
  if (length > 0) {
    bytes_processed =
        BIO_write(socket_side_, buffers_[kReadEncrypted] + start, length);
    if (bytes_processed <= 0) {
      bool retry = BIO_should_retry(socket_side_);
      if (!retry) {
        if (SSL_LOG_DATA) Log::Print(
            "BIO_write failed in ReadEncryptedBuffer\n");
      }
      bytes_processed = 0;
    }
  }
  if (SSL_LOG_DATA) Log::Print(
      "Leaving ProcessReadEncryptedBuffer wrote %d bytes\n", bytes_processed);
  return bytes_processed;
}


intptr_t SSLFilter::ProcessWriteEncryptedBuffer(int start, int end) {
  int length = end - start;
  int bytes_processed = 0;
  if (length > 0) {
    bytes_processed = BIO_read(socket_side_,
                               buffers_[kWriteEncrypted] + start,
                               length);
    if (bytes_processed < 0) {
      if (SSL_LOG_DATA) Log::Print(
          "WriteEncrypted BIO_read returned error %d\n", bytes_processed);
      return 0;
    } else {
      if (SSL_LOG_DATA) Log::Print(
          "WriteEncrypted  BIO_read wrote %d bytes\n", bytes_processed);
    }
  }
  return bytes_processed;
}

}  // namespace bin
}  // namespace dart
