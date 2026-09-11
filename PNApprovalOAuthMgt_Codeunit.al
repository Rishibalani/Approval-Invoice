// =========================================================================
//  PN Approval OAuth Mgt.
// =========================================================================
//
//  Client credentials flow against Entra ID, with a cached token that is
//  renewed BEFORE it expires rather than after it fails.
//
//  Why proactive refresh matters here: a token that expires between our check
//  and the Function's validation produces a 401 that looks identical to a
//  misconfiguration. The refresh skew (default 300 seconds, configurable on the
//  setup page) makes that race impossible in practice, and it absorbs clock
//  drift between the BC service tier and Azure.
//
//  The token itself goes to Isolated Storage, not a table field. A bearer token
//  is as good as a password for its lifetime.
// =========================================================================
codeunit 50104 "PN Approval OAuth Mgt."
{
    Access = Internal;

    var
        TokenEndpointTok: Label 'https://login.microsoftonline.com/%1/oauth2/v2.0/token', Locked = true;
        TokenRequestFailedErr: Label 'Could not obtain an access token from Entra ID. %1 %2\\%3', Comment = '%1 = status, %2 = reason, %3 = body';
        NoTokenInResponseErr: Label 'Entra ID responded but the reply contained no access_token. Check that the scope is correct and that the application has been granted the app role on the Azure Function.';
        SecretMissingErr: Label 'The Entra client secret has not been stored. Use Set Client Secret on the Approval Integration Setup page.';

    /// <summary>
    /// Returns a valid bearer token, fetching a new one only when the cached
    /// one is missing or inside the refresh window.
    /// </summary>
    procedure GetAccessToken() Token: Text
    var
        Setup: Record "PN Approval Integration Setup";
    begin
        Setup.GetSetup();

        if not Setup.IsAccessTokenStale() then
            exit(Setup.GetAccessToken());

        AcquireToken(Setup);
        exit(Setup.GetAccessToken());
    end;

    /// <summary>Forces a new token regardless of the cached one. Used by Test Connection.</summary>
    procedure ForceRefresh()
    var
        Setup: Record "PN Approval Integration Setup";
    begin
        Setup.GetSetup();
        Setup.ClearAccessToken();
        AcquireToken(Setup);
    end;

    local procedure AcquireToken(var Setup: Record "PN Approval Integration Setup")
    var
        Client: HttpClient;
        Request: HttpRequestMessage;
        Response: HttpResponseMessage;
        Content: HttpContent;
        ContentHeaders: HttpHeaders;
        ResponseText: Text;
        ClientSecret: Text;
        FormBody: Text;
        AccessToken: Text;
        ExpiresIn: Integer;
    begin
        ClientSecret := Setup.GetClientSecret();
        if ClientSecret = '' then
            Error(SecretMissingErr);

        // Standard client credentials body. The secret is placed in a local
        // variable that goes out of scope immediately after the call; it is
        // never written to a field, a log, or a telemetry dimension.
        FormBody :=
            'grant_type=client_credentials' +
            '&client_id=' + UriEscape(DelChr(Format(Setup."Entra Client ID", 0, 4), '=', '{}')) +
            '&client_secret=' + UriEscape(ClientSecret) +
            '&scope=' + UriEscape(Setup."OAuth Scope");

        Content.WriteFrom(FormBody);
        Content.GetHeaders(ContentHeaders);
        if ContentHeaders.Contains('Content-Type') then
            ContentHeaders.Remove('Content-Type');
        ContentHeaders.Add('Content-Type', 'application/x-www-form-urlencoded');

        Request.Method := 'POST';
        Request.SetRequestUri(StrSubstNo(TokenEndpointTok,
            DelChr(Format(Setup."Entra Tenant ID", 0, 4), '=', '{}')));
        Request.Content := Content;

        Client.Timeout := Setup."Request Timeout (ms)";

        if not Client.Send(Request, Response) then
            Error(TokenRequestFailedErr, 0, 'Send failed', 'The token endpoint could not be reached. Check that Allow HttpClient Requests is enabled for this extension.');

        Response.Content().ReadAs(ResponseText);

        if not Response.IsSuccessStatusCode() then
            Error(TokenRequestFailedErr,
                Response.HttpStatusCode(),
                Response.ReasonPhrase(),
                CopyStr(ResponseText, 1, 1000));

        ParseTokenResponse(ResponseText, AccessToken, ExpiresIn);

        if AccessToken = '' then
            Error(NoTokenInResponseErr);

        Setup.SetAccessToken(AccessToken, ExpiresIn);
    end;

    local procedure ParseTokenResponse(ResponseText: Text; var AccessToken: Text; var ExpiresIn: Integer)
    var
        Json: JsonObject;
        Token: JsonToken;
    begin
        if not Json.ReadFrom(ResponseText) then
            exit;

        if Json.Get('access_token', Token) then
            AccessToken := Token.AsValue().AsText();

        // Entra normally returns 3599. Default conservatively if it is absent.
        if Json.Get('expires_in', Token) then
            ExpiresIn := Token.AsValue().AsInteger()
        else
            ExpiresIn := 3000;
    end;

    // Minimal percent-encoding for the characters that actually appear in
    // client secrets and scopes. Entra secrets can contain ~ . _ - and the
    // symbols below, all of which break an unencoded form body.
    local procedure UriEscape(Value: Text): Text
    var
        Result: Text;
        Ch: Char;
        i: Integer;
    begin
        for i := 1 to StrLen(Value) do begin
            Ch := Value[i];
            case Ch of
                'A' .. 'Z', 'a' .. 'z', '0' .. '9', '-', '_', '.', '~':
                    Result += Format(Ch);
                ':', '/':
                    Result += Format(Ch);   // safe inside a scope URI
                else
                    Result += '%' + ToHex(Ch);
            end;
        end;
        exit(Result);
    end;

    local procedure ToHex(Ch: Char): Text
    var
        HexDigits: Text;
        Value: Integer;
    begin
        HexDigits := '0123456789ABCDEF';
        Value := Ch;
        exit(CopyStr(HexDigits, (Value div 16) + 1, 1) + CopyStr(HexDigits, (Value mod 16) + 1, 1));
    end;
}
