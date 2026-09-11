// =========================================================================
//  PN Approval Http Client
// =========================================================================
//
//  Bytes out, status back. This codeunit knows about HTTP, headers and
//  signatures. It does not know what an invoice is, and it must stay that way.
//
//  THREE THINGS TRAVEL WITH EVERY REQUEST
//
//  1. Authentication - who is calling. A function key, an Entra bearer token,
//     or both, depending on the setup. Answers "is this caller allowed in".
//
//  2. An HMAC signature over the raw body - what was sent. Answers "did this
//     body really come from this Business Central tenant, unmodified". A
//     function key alone cannot do this: anyone who obtains the key can post
//     any body they like. The signature binds the caller to the content.
//
//  3. An idempotency key - which logical event this is. Constant across
//     retries. Lets the Function discard duplicates, which matters because a
//     timeout is indistinguishable from a slow success and we will retry both.
//
//  The signature covers timestamp + nonce + body precisely so that a captured
//  request cannot be replayed later: the Function rejects a timestamp outside
//  a five-minute window and a nonce it has already seen.
//
//  GOTCHA: in BC SaaS this call is blocked until someone ticks "Allow
//  HttpClient Requests" on the extension in Extension Management. The failure
//  presents as a connection error, not a permissions error. The flag also
//  resets to false on every environment copy, so it has to be part of the
//  post-refresh checklist.
// =========================================================================
codeunit 50103 "PN Approval Http Client"
{
    Access = Internal;

    var
        LastHttpStatus: Integer;
        LastDurationMs: Integer;
        LastResponseBody: Text;
        ConnectErr: Label 'Could not reach %1.\\Business Central received no HTTP response at all, so the request never arrived. In order of likelihood:\1. The Azure Function is not running - check that func start is still active.\2. The dev tunnel URL has rotated - tunnel URLs change on restart unless the tunnel is persistent.\3. The tunnel is not public - open the URL in a private browser window; a Microsoft sign-in page means it is still private.\4. Allow HttpClient Requests is off for this extension in Extension Management.', Comment = '%1 = url';
        HttpErr: Label 'The dispatch endpoint returned %1 %2. %3', Comment = '%1 = status, %2 = reason, %3 = body';
        NoSigningSecretForSignErr: Label 'No HMAC signing secret is available, so the payload cannot be signed. Open Approval Integration Setup and enter the Signing Secret - it must match Dispatch__SigningSecret on the Azure Function exactly.';

    /// </summary>
    [TryFunction]
    procedure TryPost(var Outbox: Record "PN Approval Outbox"; PayloadText: Text)
    begin
        Post(Outbox, PayloadText);
    end;

    procedure Post(var Outbox: Record "PN Approval Outbox"; PayloadText: Text)
    var
        Setup: Record "PN Approval Integration Setup";
        Client: HttpClient;
        Request: HttpRequestMessage;
        Response: HttpResponseMessage;
        Content: HttpContent;
        ContentHeaders: HttpHeaders;
        RequestHeaders: HttpHeaders;
        StartTime: DateTime;
        Timestamp: Text;
        Nonce: Text;
    begin
        Setup.TestReadyForDispatch();

        Clear(LastResponseBody);
        LastHttpStatus := 0;
        LastDurationMs := 0;

        Content.WriteFrom(PayloadText);
        Content.GetHeaders(ContentHeaders);
        // WriteFrom adds a Content-Type we do not want. Add() on an existing
        // header throws rather than replacing it, so remove first.
        if ContentHeaders.Contains('Content-Type') then
            ContentHeaders.Remove('Content-Type');
        ContentHeaders.Add('Content-Type', 'application/json; charset=utf-8');

        Request.Method := 'POST';
        Request.SetRequestUri(Setup."Dispatch Endpoint URL");
        Request.Content := Content;

        Timestamp := Format(CurrentDateTime(), 0, 9);
        Nonce := DelChr(Format(CreateGuid(), 0, 4), '=', '{}');

        Request.GetHeaders(RequestHeaders);
        AddAuthHeaders(RequestHeaders, Setup);

        RequestHeaders.Add('x-pn-timestamp', Timestamp);
        RequestHeaders.Add('x-pn-nonce', Nonce);
        RequestHeaders.Add('x-pn-signature', Sign(Timestamp, Nonce, PayloadText, Setup.GetSigningSecret()));
        RequestHeaders.Add('x-pn-idempotency-key', DelChr(Format(Outbox."Idempotency Key", 0, 4), '=', '{}'));
        RequestHeaders.Add('x-pn-correlation-id', DelChr(Format(Outbox."Correlation ID", 0, 4), '=', '{}'));
        RequestHeaders.Add('x-pn-attempt', Format(Outbox."Attempt Count" + 1));
        RequestHeaders.Add('x-pn-environment', Setup."Environment Tag");
        RequestHeaders.Add('x-pn-tenant-id', Format(Database.TenantId()));
        RequestHeaders.Add('Accept', 'application/json');

        // Dev tunnels intercept requests that lack this header and return an
        // HTML anti-phishing interstitial instead of forwarding to the local
        // port. Harmless against a real Azure Function App, essential against
        // a tunnel, so it is sent unconditionally.
        RequestHeaders.Add('X-Tunnel-Skip-AntiPhishing-Page', 'true');

        Client.Timeout := Setup."Request Timeout (ms)";

        StartTime := CurrentDateTime();
        if not Client.Send(Request, Response) then
            Error(ConnectErr, Setup."Dispatch Endpoint URL");
        LastDurationMs := CurrentDateTime() - StartTime;

        LastHttpStatus := Response.HttpStatusCode();
        if not Response.Content().ReadAs(LastResponseBody) then
            LastResponseBody := '';

        // A 409 means the Function has already processed this idempotency key.
        // That is a success from our side: the event was delivered, we just
        // could not hear the first acknowledgement.
        if LastHttpStatus = 409 then
            exit;

        if not Response.IsSuccessStatusCode() then
            Error(HttpErr, LastHttpStatus, Response.ReasonPhrase(), CopyStr(LastResponseBody, 1, 500));
    end;

    /// <summary>GET against the health endpoint. Used by Test Connection.</summary>
    [TryFunction]
    procedure TryHealthCheck()
    var
        Setup: Record "PN Approval Integration Setup";
        Client: HttpClient;
        Request: HttpRequestMessage;
        Response: HttpResponseMessage;
        RequestHeaders: HttpHeaders;
        Url: Text;
    begin
        Setup.GetSetup();

        Url := Setup."Health Endpoint URL";
        if Url = '' then
            Url := Setup."Dispatch Endpoint URL";

        Request.Method := 'GET';
        Request.SetRequestUri(Url);
        Request.GetHeaders(RequestHeaders);
        AddAuthHeaders(RequestHeaders, Setup);
        RequestHeaders.Add('x-pn-environment', Setup."Environment Tag");
        RequestHeaders.Add('X-Tunnel-Skip-AntiPhishing-Page', 'true');

        Client.Timeout := Setup."Request Timeout (ms)";

        if not Client.Send(Request, Response) then
            Error(ConnectErr, Url);

        LastHttpStatus := Response.HttpStatusCode();
        Response.Content().ReadAs(LastResponseBody);

        if not Response.IsSuccessStatusCode() then
            Error(HttpErr, LastHttpStatus, Response.ReasonPhrase(), CopyStr(LastResponseBody, 1, 500));
    end;

    local procedure AddAuthHeaders(var RequestHeaders: HttpHeaders; var Setup: Record "PN Approval Integration Setup")
    var
        OAuthMgt: Codeunit "PN Approval OAuth Mgt.";
        FunctionKey: Text;
    begin
        case Setup."Auth Mode" of
            Setup."Auth Mode"::"Function Key":
                begin
                    FunctionKey := Setup.GetFunctionKey();
                    if FunctionKey <> '' then
                        RequestHeaders.Add('x-functions-key', FunctionKey);
                end;
            Setup."Auth Mode"::"OAuth2 Client Credentials":
                RequestHeaders.Add('Authorization', 'Bearer ' + OAuthMgt.GetAccessToken());
            Setup."Auth Mode"::Both:
                begin
                    FunctionKey := Setup.GetFunctionKey();
                    if FunctionKey <> '' then
                        RequestHeaders.Add('x-functions-key', FunctionKey);
                    RequestHeaders.Add('Authorization', 'Bearer ' + OAuthMgt.GetAccessToken());
                end;
        end;
    end;

    procedure Sign(Timestamp: Text; Nonce: Text; Body: Text; SigningSecret: Text): Text
    var
        CryptographyManagement: Codeunit "Cryptography Management";
        StringToSign: Text;
    begin
        // Never send an unsigned request. Returning an empty signature here
        // produces a 401 from the Function that reads like a mismatched secret
        // rather than a missing one - two very different problems that would
        // otherwise present identically on the outbox row.
        if SigningSecret = '' then
            Error(NoSigningSecretForSignErr);

        StringToSign := Timestamp + '.' + Nonce + '.' + Body;
        exit(CryptographyManagement.GenerateHashAsBase64String(StringToSign, SigningSecret, 2));
    end;

    procedure GetLastHttpStatus(): Integer
    begin
        exit(LastHttpStatus);
    end;

    procedure GetLastDurationMs(): Integer
    begin
        exit(LastDurationMs);
    end;

    procedure GetLastResponseBody(): Text
    begin
        exit(LastResponseBody);
    end;
}
