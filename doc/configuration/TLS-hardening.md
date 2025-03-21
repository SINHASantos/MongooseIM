## OTP TLS vs. Fast TLS

Before we explain the TLS hardening in MongooseIM, we need to describe the TLS libraries used in the project.
These are "OTP TLS" and "Fast TLS".

The former is provided by (as the name suggests) OTP as the `ssl` application.
Large part of the logic is implemented in Erlang but it calls OpenSSL API for some operations anyway.

The latter is a community-maintained driver, which is implemented as NIFs (native C code).
It uses OpenSSL API for all operations.

Most MongooseIM components use the TLS library provided by OTP.
However, some of them choose to integrate with `fast_tls` library instead.
The former one is used primarily by MIM dependencies, while the latter is used only by MIM modules.

None of them is strictly better than the other.
Below you may find a summary of the differences between them.

* `fast_tls` used to be faster, however with the progress of OTP TLS implementation
and additional optimisations applied in MongooseIM this is no longer true.
* `just_tls` may use slightly more processor time than `fast_tls`.
* There are options that OTP TLS (a.k.a `just_tls` in the C2S listener configuration) supports exclusively:
    * Immediate connection drop when the client certificate is invalid
    * Certificate Revocation Lists
    * More flexible certificate verification options
* Allowed protocol versions may be configured:
    * Globally for OTP TLS via an environment variable
    * Per socket in Fast TLS via OpenSSL cipher string

## Deprecations

MongooseIM is configured to allow only TLS 1.2 or higher, due to known vulnerabilities in TLS 1.0 and 1.1.
It is still possible to enable earlier versions, however it is strongly discouraged.

## OTP TLS hardening

Protocol list for OTP TLS is set via the `protocol_version` environment variable.
It's an Erlang runtime variable, so it is not configured in the OS but rather in the`app.config` file.
It may be found in `etc/` folder inside MongooseIM release and in `[repository root]/rel/files/`.

In order to change the list, please find the following lines:

```
{protocol_version, ['tlsv1.2',
                    'tlsv1.3'
          ]}
```

The remaining valid values are: `'tlsv1.1'`, `tlsv1`, `sslv3`.

This setting affects the following MongooseIM components:

* Raw XMPP over TCP connections (C2S listener) in the default configuration uses `just_tls`
* All outgoing connections (databases, AMQP, SIP etc.)
* HTTP endpoints

## Fast TLS hardening

Fast TLS expects an OpenSSL cipher string as one of optional connection parameters.
This string is configured individually for every module that uses it.
By default, MongooseIM sets this option to `TLSv1.2:TLSv1.3` for each component.

The list below enumerates all components that use Fast TLS and describes how to change this string.

* `listen.c2s` - main user session abstraction + XMPP over TCP listener, when configured to use `fast_tls`
    * Note that usage of `fast_tls` for C2S has been deprecated
    * Please consult the respective section in [Listener modules](../listeners/listen-c2s.md#listenc2stlsprotocol_options-only-for-fast_tls).
* `listen.s2s` - incoming S2S connections (XMPP Federation)
    * Please consult the respective section in [Listener modules](../listeners/listen-s2s.md#tls-options-for-s2s).
* `s2s` - outgoing S2S connections (XMPP Federation)
    * Please check [the documentation](s2s.md#s2sciphers) for `s2s_ciphers` option.
* `mod_global_distrib` - Global Distribution module
    * Please add `connections.tls.ciphers = "string"` to `modules.mod_global_distrib` module, as [described in the documentation](../modules/mod_global_distrib.md#tls-options).
