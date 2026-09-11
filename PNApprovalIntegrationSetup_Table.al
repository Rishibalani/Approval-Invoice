// =========================================================================
//  PN Approval Integration Setup  -  singleton configuration
// =========================================================================
//
//  Follows the same shape as the existing "OCR Setup" table in
//  PulseNet365_Finance: blank Code[10] primary key, GetSetup() creates the row
//  on first use, and NO SECRET IS EVER STORED IN A FIELD.
//
//  Secrets (function key, HMAC signing secret, Entra client secret) live in
//  Isolated Storage. The table only records a Boolean saying whether each one
//  has been set, so the values cannot leak through a page, a RapidStart
//  package, a database export, or a support session.
//
//  Everything an operator might need to change without a redeploy is a field
//  here: endpoint, auth mode, tenant/client IDs, timeouts, retry policy,
//  batch size, amount thresholds, and which document types are in scope.
// =========================================================================
table 50102 "PN Approval Integration Setup"
{
    Caption = 'Approval Integration Setup';
    DataClassification = CustomerContent;

    fields
    {
        field(1; "Primary Key"; Code[10])
        {
            Caption = 'Primary Key';
            DataClassification = SystemMetadata;
        }

        // ---------------------------------------------------------------
        //  Master switch and endpoint
        // ---------------------------------------------------------------
        field(10; Enabled; Boolean)
        {
            Caption = 'Enabled';
            ToolTip = 'Turns the whole integration on. When off, the event subscriber still writes outbox rows but the Job Queue runner does not dispatch them, so nothing is lost while the integration is paused.';
        }
        field(11; "Dispatch Endpoint URL"; Text[250])
        {
            Caption = 'Dispatch Endpoint URL';
            ToolTip = 'Full HTTPS endpoint of the Azure Function that receives approval payloads, e.g. https://pulsenet-approvals.azurewebsites.net/api/approvals/dispatch';

            trigger OnValidate()
            begin
                if "Dispatch Endpoint URL" = '' then
                    exit;
                if LowerCase(CopyStr("Dispatch Endpoint URL", 1, 8)) <> 'https://' then
                    Error(HttpsOnlyErr);
            end;
        }
        field(12; "Health Endpoint URL"; Text[250])
        {
            Caption = 'Health Endpoint URL';
            ToolTip = 'Optional GET endpoint used by the Test Connection action, e.g. https://pulsenet-approvals.azurewebsites.net/api/health';
        }
        field(13; "Environment Tag"; Code[20])
        {
            Caption = 'Environment Tag';
            InitValue = 'SANDBOX';
            ToolTip = 'Free-text tag sent with every payload (SANDBOX, UAT, PROD). The Azure Function uses it to refuse cross-environment traffic - a production Function can reject anything not tagged PROD.';
        }

        // ---------------------------------------------------------------
        //  Authentication - switchable at runtime
        // ---------------------------------------------------------------
        field(20; "Auth Mode"; Enum "PN Dispatch Auth Mode")
        {
            Caption = 'Authentication Mode';
            InitValue = "Function Key";
            ToolTip = 'How Business Central authenticates to the Azure Function. Change this without redeploying the extension.';
        }
        field(21; "Function Key Set"; Boolean)
        {
            Caption = 'Function Key Set';
            Editable = false;
            ToolTip = 'Shows whether a function key is stored in Isolated Storage. The key itself is never shown.';
        }
        field(22; "Signing Secret Set"; Boolean)
        {
            Caption = 'Signing Secret Set';
            Editable = false;
            ToolTip = 'Shows whether the HMAC signing secret is stored. This secret proves to the Azure Function that a payload really came from this Business Central tenant and was not tampered with in transit.';
        }
        field(23; "Entra Tenant ID"; Guid)
        {
            Caption = 'Entra Tenant ID';
            ToolTip = 'Directory (tenant) ID used for the OAuth 2.0 token request.';
        }
        field(24; "Entra Client ID"; Guid)
        {
            Caption = 'Entra Client ID';
            ToolTip = 'Application (client) ID of the Entra app registration that represents Business Central when calling the Azure Function.';
        }
        field(25; "Client Secret Set"; Boolean)
        {
            Caption = 'Client Secret Set';
            Editable = false;
        }
        field(26; "OAuth Scope"; Text[250])
        {
            Caption = 'OAuth Scope';
            ToolTip = 'Scope requested in the client credentials flow, normally api://<function-app-client-id>/.default';
        }
        field(27; "Token Expires At"; DateTime)
        {
            Caption = 'Token Expires At';
            Editable = false;
            ToolTip = 'When the cached access token stops being valid. The dispatcher refreshes before this moment using the skew below, so a token never expires mid-flight.';
        }
        field(28; "Token Refresh Skew (Sec.)"; Integer)
        {
            Caption = 'Token Refresh Skew (Seconds)';
            InitValue = 300;
            MinValue = 30;
            MaxValue = 1800;
            ToolTip = 'How many seconds before real expiry the token is proactively renewed. 300 covers clock drift plus a slow call.';
        }
        field(29; "Client Secret Expiry Date"; Date)
        {
            Caption = 'Client Secret Expiry Date';
            ToolTip = 'Reminder only. Record the expiry date shown in Entra ID so the secret can be rotated before it lapses - an expired secret silently breaks every dispatch.';
        }

        // ---------------------------------------------------------------
        //  Transport behaviour
        // ---------------------------------------------------------------
        field(40; "Request Timeout (ms)"; Integer)
        {
            Caption = 'Request Timeout (ms)';
            InitValue = 30000;
            MinValue = 5000;
            MaxValue = 120000;
        }
        field(41; "Max Attempts"; Integer)
        {
            Caption = 'Max Attempts';
            InitValue = 6;
            MinValue = 1;
            MaxValue = 20;
            ToolTip = 'After this many failed attempts the row moves to Failed and stops retrying. With the default backoff, 6 attempts spans roughly one hour.';
        }
        field(42; "Retry Base Delay (Sec.)"; Integer)
        {
            Caption = 'Retry Base Delay (Seconds)';
            InitValue = 30;
            MinValue = 5;
            MaxValue = 3600;
            ToolTip = 'First retry waits this long. Each subsequent retry doubles it: 30s, 60s, 120s, 240s, and so on.';
        }
        field(43; "Batch Size"; Integer)
        {
            Caption = 'Batch Size';
            InitValue = 25;
            MinValue = 1;
            MaxValue = 500;
            ToolTip = 'Maximum rows drained per Job Queue run. Keep this modest so a single run cannot exceed the Job Queue timeout.';
        }
        field(44; "Log Retention (Days)"; Integer)
        {
            Caption = 'Log Retention (Days)';
            InitValue = 90;
            MinValue = 0;
            ToolTip = 'Sent and Skipped outbox rows older than this are deleted by the runner. 0 keeps everything.';
        }
        field(45; "Alert Email Recipients"; Text[250])
        {
            Caption = 'Alert Email Recipients';
            ToolTip = 'Comma-separated addresses notified when an outbox row exhausts its retries. Uses the standard Business Central email setup.';
        }

        // ---------------------------------------------------------------
        //  Scope and financial policy
        // ---------------------------------------------------------------
        field(60; "Include Purchase Documents"; Boolean)
        {
            Caption = 'Include Purchase Documents';
            InitValue = true;
        }
        field(61; "Include Sales Documents"; Boolean)
        {
            Caption = 'Include Sales Documents';
            InitValue = true;
        }
        field(62; "Min. Amount (LCY)"; Decimal)
        {
            Caption = 'Minimum Amount (LCY)';
            InitValue = 0;
            MinValue = 0;
            AutoFormatType = 1;
            ToolTip = 'Approval requests below this value are not dispatched at all - the approver handles them in Business Central. Set to 0 to dispatch everything.';
        }
        field(63; "High Value Threshold (LCY)"; Decimal)
        {
            Caption = 'High Value Threshold (LCY)';
            InitValue = 0;
            MinValue = 0;
            AutoFormatType = 1;
            ToolTip = 'At or above this value the payload is flagged high value. The Azure Function suppresses one-tap approval and sends a notify-only card with a deep link into Business Central, so the approver must sign in. Set to 0 to disable tiering.';
        }
        field(64; "Block On Vendor Bank Change"; Boolean)
        {
            Caption = 'Block Fast Approval On Vendor Bank Change';
            InitValue = true;
            ToolTip = 'If the vendor bank account details changed after the invoice was created, the payload is flagged and in-channel approval is suppressed. This is the single most common payment-fraud vector in accounts payable.';
        }
        field(65; "Include Document Lines"; Boolean)
        {
            Caption = 'Include Document Lines In Payload';
            InitValue = false;
            ToolTip = 'Off by default for data minimisation. Line detail is rarely needed to make an approval decision and increases the blast radius if a channel is compromised.';
        }
        field(66; "BC Base URL"; Text[250])
        {
            Caption = 'Business Central Base URL';
            ToolTip = 'Used to build the deep link placed on every card, e.g. https://businesscentral.dynamics.com/<tenant-id>. Leave blank to have the extension derive it automatically.';
        }

        // ---------------------------------------------------------------
        //  Channel control - GLOBAL, not per user
        //
        //  These are the only switches that decide where a payload goes.
        //  Turning one off stops that channel for everybody, immediately,
        //  with no redeploy and nothing to change on the Azure side.
        //
        //  Azure reads the resulting list from the payload and obeys it. It
        //  has no opinion of its own about which channels are in use - its
        //  own configuration says only HOW a channel is reached, never
        //  whether.
        // ---------------------------------------------------------------
        field(70; "Teams Channel Enabled"; Boolean)
        {
            Caption = 'Teams';
            InitValue = true;
            ToolTip = 'Send approval cards to Microsoft Teams. Applies to every approver.';
        }
        field(71; "Outlook Channel Enabled"; Boolean)
        {
            Caption = 'Outlook';
            InitValue = false;
            ToolTip = 'Send approval emails through Outlook. Applies to every approver.';
        }
        field(72; "WhatsApp Channel Enabled"; Boolean)
        {
            Caption = 'WhatsApp';
            InitValue = false;
            ToolTip = 'Send approval messages through WhatsApp. Applies to every approver. Requires an approved Meta template and recorded consent.';
        }
        field(73; "Global Fallback Channel"; Enum "PN Approval Channel")
        {
            Caption = 'Fallback Channel';
            InitValue = Outlook;
            ToolTip = 'Tried when every enabled channel fails. Outlook is the safe default because every approver has a mailbox, which is not true of a Teams app install.';
        }

        // ---------------------------------------------------------------
        //  Diagnostics
        // ---------------------------------------------------------------
        field(80; "Last Dispatch At"; DateTime)
        {
            Caption = 'Last Successful Dispatch At';
            Editable = false;
        }
        field(81; "Last Error"; Text[250])
        {
            Caption = 'Last Error';
            Editable = false;
        }
        field(82; "Verbose Logging"; Boolean)
        {
            Caption = 'Verbose Logging';
            ToolTip = 'Stores the full request and response body on each outbox row. Useful while building, expensive and privacy-sensitive in production.';
        }
    }

    keys
    {
        key(PK; "Primary Key") { Clustered = true; }
    }

    var
        HttpsOnlyErr: Label 'The dispatch endpoint must use HTTPS.';
        FunctionKeyTok: Label 'PN-APPROVAL-FUNCTION-KEY', Locked = true;
        SigningSecretTok: Label 'PN-APPROVAL-SIGNING-SECRET', Locked = true;
        ClientSecretTok: Label 'PN-APPROVAL-CLIENT-SECRET', Locked = true;
        AccessTokenTok: Label 'PN-APPROVAL-ACCESS-TOKEN', Locked = true;

    /// <summary>Singleton accessor. Call before reading any setting.</summary>
    procedure GetSetup()
    begin
        if not Get() then begin
            Init();
            Insert(true);
        end;
    end;

    procedure SetFunctionKey(NewKey: Text)
    begin
        // GetSetup first: these are called from pages and codeunits alike, and a
        // Modify on an unloaded record fails in a way that looks like the secret
        // was rejected rather than never attempted.
        GetSetup();
        "Function Key Set" := StoreSecret(FunctionKeyTok, NewKey);
        Modify(true);
    end;

    procedure GetFunctionKey() Result: Text
    begin
        exit(ReadSecret(FunctionKeyTok));
    end;

    procedure SetSigningSecret(NewSecret: Text)
    begin
        // GetSetup first: these are called from pages and codeunits alike, and a
        // Modify on an unloaded record fails in a way that looks like the secret
        // was rejected rather than never attempted.
        GetSetup();
        "Signing Secret Set" := StoreSecret(SigningSecretTok, NewSecret);
        Modify(true);
    end;

    procedure GetSigningSecret() Result: Text
    begin
        exit(ReadSecret(SigningSecretTok));
    end;

    procedure SetClientSecret(NewSecret: Text)
    begin
        GetSetup();
        "Client Secret Set" := StoreSecret(ClientSecretTok, NewSecret);
        // A new secret invalidates any cached token immediately.
        ClearAccessToken();
        Modify(true);
    end;

    procedure GetClientSecret() Result: Text
    begin
        exit(ReadSecret(ClientSecretTok));
    end;

    /// <summary>
    /// Re-derives the three Set flags from what is genuinely retrievable in
    /// Isolated Storage. Table data survives an environment copy or a restore;
    /// Isolated Storage does not always. That combination leaves a flag saying
    /// Yes with nothing behind it, which then fails at dispatch time with a
    /// confusing message.
    /// </summary>
    procedure ReconcileSecretFlags()
    begin
        GetSetup();
        "Function Key Set" := GetFunctionKey() <> '';
        "Signing Secret Set" := GetSigningSecret() <> '';
        "Client Secret Set" := GetClientSecret() <> '';
        Modify(true);
    end;

    procedure SetAccessToken(Token: Text; ExpiresInSeconds: Integer)
    begin
        GetSetup();
        if StoreSecret(AccessTokenTok, Token) then
            "Token Expires At" := CurrentDateTime() + (ExpiresInSeconds * 1000)
        else
            "Token Expires At" := 0DT;
        Modify(true);
    end;

    procedure GetAccessToken() Result: Text
    begin
        exit(ReadSecret(AccessTokenTok));
    end;

    procedure ClearAccessToken()
    begin
        StoreSecret(AccessTokenTok, '');
        "Token Expires At" := 0DT;
    end;

    procedure IsAccessTokenStale(): Boolean
    begin
        if "Token Expires At" = 0DT then
            exit(true);
        if GetAccessToken() = '' then
            exit(true);
        exit(CurrentDateTime() >= ("Token Expires At" - ("Token Refresh Skew (Sec.)" * 1000)));
    end;

        local procedure StoreSecret(TokenName: Text; SecretValue: Text): Boolean
    var
        VerifyValue: Text;
    begin
        if SecretValue = '' then begin
            if IsolatedStorage.Contains(TokenName, DataScope::Company) then
                if not IsolatedStorage.Delete(TokenName, DataScope::Company) then
                    exit(false);
            exit(false);
        end;

        IsolatedStorage.Set(TokenName, SecretValue, DataScope::Company);

        // Read it back. The Boolean on the record is what every readiness check
        // trusts, so it must reflect what is actually in storage rather than
        // what we intended to put there. A silent no-op here surfaces much
        // later as a confusing "no key stored" error at dispatch time.
        if not IsolatedStorage.Get(TokenName, DataScope::Company, VerifyValue) then
            exit(false);

        exit(VerifyValue = SecretValue);
    end;

    local procedure ReadSecret(TokenName: Text) Result: Text
    begin
        if not IsolatedStorage.Get(TokenName, DataScope::Company, Result) then
            exit('');
    end;

    /// <summary>Guard called before any dispatch attempt.</summary>
    //     case "Auth Mode" of
    //         "Auth Mode"::"Function Key":
    //             TestField("Function Key Set");
    //         "Auth Mode"::"OAuth2 Client Credentials":
    //             TestOAuthFields();
    //         "Auth Mode"::Both:
    //             begin
    //                 TestField("Function Key Set");
    //                 TestOAuthFields();
    //             end;
    //     end;
    // end;


        /// <summary>Guard called before any dispatch attempt.</summary>
    procedure TestReadyForDispatch()
    begin
        GetSetup();

        // Deliberately not TestField. That produces "must have a value in
        // Approval Integration Setup: Primary Key=", which lands in the outbox
        // Last Error column and tells whoever reads it nothing actionable.
        if not Enabled then
            Error(NotEnabledErr);

        if "Dispatch Endpoint URL" = '' then
            Error(NoEndpointErr);

        // Check Isolated Storage itself, not the Boolean. The Boolean records
        // what we intended to write; storage holds what is actually there.
        // They diverge after a republish, because table data survives and
        // Isolated Storage does not always. When they diverge, the flag passes
        // this check while dispatch sends an empty signature and collects a
        // 401 that looks like a mismatched secret rather than a missing one.
        if GetSigningSecret() = '' then
            Error(NoSigningSecretErr);

        case "Auth Mode" of
            "Auth Mode"::"Function Key":
                CheckFunctionKey();
            "Auth Mode"::"OAuth2 Client Credentials":
                CheckOAuthFields();
            "Auth Mode"::Both:
                begin
                    CheckFunctionKey();
                    CheckOAuthFields();
                end;
        end;
    end;

    local procedure CheckFunctionKey()
    begin
        if GetFunctionKey() = '' then
            Error(NoFunctionKeyErr);
    end;

    local procedure CheckOAuthFields()
    begin
        if IsNullGuid("Entra Tenant ID") then
            Error(NoOAuthFieldErr, 'Entra Tenant ID');
        if IsNullGuid("Entra Client ID") then
            Error(NoOAuthFieldErr, 'Entra Client ID');
        if GetClientSecret() = '' then
            Error(NoOAuthFieldErr, 'Entra client secret');
        if "OAuth Scope" = '' then
            Error(NoOAuthFieldErr, 'OAuth Scope');
    end;

    /// <summary>
    /// The channels that are switched on right now. This is the whole channel
    /// decision - the payload builder writes it into every payload, and the
    /// Azure Function sends to exactly these and nothing else.
    /// </summary>
    procedure GetEnabledChannels() Channels: List of [Text]
    begin
        GetSetup();

        if "Teams Channel Enabled" then
            Channels.Add('Teams');
        if "Outlook Channel Enabled" then
            Channels.Add('Outlook');
        if "WhatsApp Channel Enabled" then
            Channels.Add('WhatsApp');
    end;

    procedure AnyChannelEnabled(): Boolean
    begin
        GetSetup();
        exit("Teams Channel Enabled" or "Outlook Channel Enabled" or "WhatsApp Channel Enabled");
    end;

    procedure BuildDeepLink(PageId: Integer; RecVariant: Variant): Text
    var
        TypeHelper: Codeunit "Type Helper";
        BaseUrl: Text;
        Encoded: Text;
        DocumentNo: Code[20];
        RecRef: RecordRef;
    begin
        GetSetup();

        // Preferred: let the platform build it. In SaaS this returns the full
        // https://businesscentral.dynamics.com/{tenant}/{env}?company=...&bookmark=...
        // form, correctly encoded, pointing at this exact record.
        if RecVariant.IsRecord() then begin
            RecRef.GetTable(RecVariant);
            exit(GetUrl(ClientType::Web, CompanyName(), ObjectType::Page, PageId, RecRef));
        end;
        // Fallback: filter-style link when no record was supplied.
        BaseUrl := "BC Base URL";
        if BaseUrl = '' then
            BaseUrl := GetUrl(ClientType::Web);

        RecRef.GetTable(RecVariant);
        DocumentNo := '';
        Encoded := '%27' + DocumentNo + '%27';

        exit(BaseUrl +
            '?company=' + TypeHelper.UriEscapeDataString(CompanyName()) +
            '&page=' + Format(PageId) +
            '&filter=' + '%27No.%27%20IS%20' + Encoded);
    end;

    var
        NotEnabledErr: Label 'The approval integration is switched off. Tick Enabled on the Approval Integration Setup page.';
        NoEndpointErr: Label 'No dispatch endpoint is configured. Set the Dispatch Endpoint URL on the Approval Integration Setup page.';
        NoSigningSecretErr: Label 'No HMAC signing secret is stored. On the Approval Integration Setup page, use Generate Signing Secret, then copy the value into the Azure Function setting Dispatch__SigningSecret.';
        NoFunctionKeyErr: Label 'No Azure Function key is stored. Use Set Function Key on the Approval Integration Setup page.';
        NoOAuthFieldErr: Label '%1 is required when the authentication mode uses Entra ID.', Comment = '%1 = field name';
}
