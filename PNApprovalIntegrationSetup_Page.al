// =========================================================================
//  PN Approval Integration Setup  -  page
// =========================================================================
//
//  SECRETS ARE ENTERED INLINE, NOT THROUGH A MODAL
//
//  An earlier version collected secrets through a StandardDialog page and
//  stored whatever it returned. When that dialog handed back an empty string -
//  which it did silently - StoreSecret wrote nothing, the Boolean stayed off,
//  and the only symptom appeared much later as "No Azure Function key is
//  stored" at dispatch time. Several layers between cause and effect.
//
//  These three fields are page variables, never table fields, so the value
//  still never touches the database. They are masked on screen and cleared
//  the instant they are stored, so the secret exists in memory for one
//  round trip and nowhere else.
//
//  The Boolean beside each one is the honest indicator: it reflects a
//  successful read-back from Isolated Storage, not merely an intention to
//  write. If it says Yes, the value is genuinely retrievable.
// =========================================================================
page 50104 "PN Approval Integration Setup"
{
    Caption = 'Approval Integration Setup';
    PageType = Card;
    ApplicationArea = All;
    UsageCategory = Administration;
    SourceTable = "PN Approval Integration Setup";
    InsertAllowed = false;
    DeleteAllowed = false;
    AboutTitle = 'Approval Integration Setup';
    AboutText = 'Everything the approval bridge needs at runtime lives here. Endpoints, keys, thresholds and retry behaviour can all be changed without republishing the extension.';

    layout
    {
        area(Content)
        {
            group(General)
            {
                Caption = 'General';

                field(Enabled; Rec.Enabled) { ApplicationArea = All; }
                field("Environment Tag"; Rec."Environment Tag") { ApplicationArea = All; }
                field("Dispatch Endpoint URL"; Rec."Dispatch Endpoint URL") { ApplicationArea = All; }
                field("Health Endpoint URL"; Rec."Health Endpoint URL") { ApplicationArea = All; }
                field("BC Base URL"; Rec."BC Base URL") { ApplicationArea = All; }
            }

            group(Authentication)
            {
                Caption = 'Authentication';

                field("Auth Mode"; Rec."Auth Mode")
                {
                    ApplicationArea = All;

                    trigger OnValidate()
                    begin
                        RefreshVisibility();
                        // false, not true: passing true asks the framework to
                        // save mid-validation, which can raise "the record has
                        // been modified by another user" on a Card page.
                        CurrPage.Update(false);
                    end;
                }

                group(FunctionKeyGroup)
                {
                    Caption = 'Azure Function Key';
                    Visible = ShowFunctionKey;

                    field(FunctionKeyInput; FunctionKeyInput)
                    {
                        ApplicationArea = All;
                        Caption = 'Function Key';
                        ExtendedDatatype = Masked;
                        ToolTip = 'Paste the Azure Function key here and press Enter. It is written to Isolated Storage and this box is cleared immediately. Running locally with func start, any placeholder works - the local runtime ignores the key entirely.';

                        trigger OnValidate()
                        begin
                            StoreFunctionKey();
                        end;
                    }
                    field(FunctionKeyStored; FunctionKeyStored)
                    {
                        ApplicationArea = All;
                        Caption = 'Stored';
                        Editable = false;
                        StyleExpr = FunctionKeyStyle;
                        ToolTip = 'Yes means the key is genuinely retrievable from Isolated Storage right now. This is a status indicator, not a switch.';
                    }
                }

                group(SigningSecretGroup)
                {
                    Caption = 'HMAC Signing Secret';

                    field(SigningSecretInput; SigningSecretInput)
                    {
                        ApplicationArea = All;
                        Caption = 'Signing Secret';
                        ExtendedDatatype = Masked;
                        ToolTip = 'Must match the Azure Function setting Dispatch__SigningSecret byte for byte. A mismatch produces a bare 401 with no explanation, so paste rather than type.';

                        trigger OnValidate()
                        begin
                            StoreSigningSecret();
                        end;
                    }
                    field(SigningSecretStored; SigningSecretStored)
                    {
                        ApplicationArea = All;
                        Caption = 'Stored';
                        Editable = false;
                        StyleExpr = SigningSecretStyle;
                    }
                }

                group(EntraGroup)
                {
                    Caption = 'Microsoft Entra ID';
                    Visible = ShowEntraFields;

                    field("Entra Tenant ID"; Rec."Entra Tenant ID") { ApplicationArea = All; }
                    field("Entra Client ID"; Rec."Entra Client ID") { ApplicationArea = All; }

                    field(ClientSecretInput; ClientSecretInput)
                    {
                        ApplicationArea = All;
                        Caption = 'Client Secret';
                        ExtendedDatatype = Masked;
                        ToolTip = 'The Entra application client secret. Storing a new value clears the cached access token immediately.';

                        trigger OnValidate()
                        begin
                            StoreClientSecret();
                        end;
                    }
                    field(ClientSecretStored; ClientSecretStored)
                    {
                        ApplicationArea = All;
                        Caption = 'Stored';
                        Editable = false;
                        StyleExpr = ClientSecretStyle;
                    }
                    field("Client Secret Expiry Date"; Rec."Client Secret Expiry Date")
                    {
                        ApplicationArea = All;
                        StyleExpr = SecretExpiryStyle;
                    }
                    field("Secret Expiry Warning (Days)"; Rec."Secret Expiry Warning (Days)")
                    {
                        ApplicationArea = All;
                        ToolTip = 'How many days before the Client Secret Expiry Date the date is highlighted as a warning. 0 highlights it only once it has passed.';

                        trigger OnValidate()
                        begin
                            RefreshVisibility();
                        end;
                    }
                    field("OAuth Scope"; Rec."OAuth Scope") { ApplicationArea = All; }
                    field("OAuth Authority URL"; Rec."OAuth Authority URL")
                    {
                        ApplicationArea = All;
                        ToolTip = 'Entra ID authority host used for the client credentials token request, without the tenant or path, e.g. https://login.microsoftonline.com. Change it only for a sovereign cloud. The tenant ID and /oauth2/v2.0/token are appended automatically.';
                    }
                    field("Token Expires At"; Rec."Token Expires At") { ApplicationArea = All; }
                    field("Token Refresh Skew (Sec.)"; Rec."Token Refresh Skew (Sec.)") { ApplicationArea = All; }
                    field("Token Lifetime Fallback (Sec.)"; Rec."Token Lifetime Fallback (Sec.)")
                    {
                        ApplicationArea = All;
                        ToolTip = 'Lifetime assumed for an access token when Entra ID does not return expires_in. Entra normally returns about 3599 seconds; keep this below that.';
                    }
                }
            }

            group(Scope)
            {
                Caption = 'Scope';

                field("Include Purchase Documents"; Rec."Include Purchase Documents") { ApplicationArea = All; }
                field("Include Sales Documents"; Rec."Include Sales Documents") { ApplicationArea = All; }
                field("Min. Amount (LCY)"; Rec."Min. Amount (LCY)") { ApplicationArea = All; }
                field("Include Document Lines"; Rec."Include Document Lines") { ApplicationArea = All; }
            }

            group(ActionLinks)
            {
                Caption = 'Approval Links';
                InstructionalText = 'Business Central builds the Approve and Reject links in every email. Azure validates them and records the decision, so both sides must share the same secret.';

                field("Action Endpoint URL"; Rec."Action Endpoint URL") { ApplicationArea = All; }

                field(ActionTokenInput; ActionTokenInput)
                {
                    ApplicationArea = All;
                    Caption = 'Action Token Secret';
                    ExtendedDatatype = Masked;
                    ToolTip = 'Must match ActionToken__SigningSecret on the Azure Function byte for byte. A mismatch makes every link fail with no explanation, so paste rather than type.';

                    trigger OnValidate()
                    begin
                        StoreActionTokenSecret();
                    end;
                }
                field(ActionTokenStored; ActionTokenStored)
                {
                    ApplicationArea = All;
                    Caption = 'Stored';
                    Editable = false;
                    StyleExpr = ActionTokenStyle;
                }
                field("Action Token TTL (Min.)"; Rec."Action Token TTL (Min.)") { ApplicationArea = All; }
            }

            group(FinancialControls)
            {
                Caption = 'Financial Controls';

                field("High Value Threshold (LCY)"; Rec."High Value Threshold (LCY)") { ApplicationArea = All; }
                field("Outlook Max Approve (LCY)"; Rec."Outlook Max Approve (LCY)") { ApplicationArea = All; }
                field("Block On Vendor Bank Change"; Rec."Block On Vendor Bank Change")
                {
                    ApplicationArea = All;

                    trigger OnValidate()
                    begin
                        if Rec."Block On Vendor Bank Change" then
                            Message(ChangeLogReminderMsg, Rec."Bank Change Table No.", Rec."Bank Change Field Filter");
                    end;
                }
                field("Bank Change Table No."; Rec."Bank Change Table No.")
                {
                    ApplicationArea = All;
                    ToolTip = 'Table whose Change Log entries are checked for bank-detail changes. 23 is the Vendor table. The Change Log must be active for this table.';
                }
                field("Bank Change Field Filter"; Rec."Bank Change Field Filter")
                {
                    ApplicationArea = All;
                    ToolTip = 'Field numbers on that table that count as bank details, as a filter such as 288|289|290 (Bank Account No., Bank Branch No., IBAN). Field numbers differ by localisation - verify them. Used both when the notification is sent and when an approval arrives.';
                }
                field("Amount Tolerance (LCY)"; Rec."Amount Tolerance (LCY)")
                {
                    ApplicationArea = All;
                    ToolTip = 'When an approval arrives from a channel, it is refused if the document amount (LCY) differs from the amount on the notification by more than this. Absorbs rounding only; 0 requires an exact match.';
                }
            }

            group(Transport)
            {
                Caption = 'Delivery and Retry';

                field("Request Timeout (ms)"; Rec."Request Timeout (ms)") { ApplicationArea = All; }
                field("Max Attempts"; Rec."Max Attempts") { ApplicationArea = All; }
                field("Retry Base Delay (Sec.)"; Rec."Retry Base Delay (Sec.)") { ApplicationArea = All; }
                field("Max Retry Delay (Sec.)"; Rec."Max Retry Delay (Sec.)")
                {
                    ApplicationArea = All;
                    ToolTip = 'Upper limit on the doubling retry delay, so a long outage does not push the next attempt far into the future.';
                }
                field("Created Hold Delay (Sec.)"; Rec."Created Hold Delay (Sec.)")
                {
                    ApplicationArea = All;
                    ToolTip = 'While Business Central has not yet opened an approval entry (status Created), the outbox row is held and looked at again after this many seconds. Holding does not count as a failed attempt.';
                }
                field("Batch Size"; Rec."Batch Size") { ApplicationArea = All; }
                field("Job Queue Minutes Between Runs"; Rec."Job Queue Minutes Between Runs")
                {
                    ApplicationArea = All;
                    ToolTip = 'Recurrence used when Create Job Queue Entry creates the dispatch job. An existing Job Queue Entry is not changed - edit it directly, or delete it and create it again.';
                }
                field("Job Queue Max Attempts"; Rec."Job Queue Max Attempts")
                {
                    ApplicationArea = All;
                    ToolTip = 'Maximum No. of Attempts to Run set on the dispatch Job Queue Entry when Create Job Queue Entry creates it. An existing entry is not changed.';
                }
                field("Log Retention (Days)"; Rec."Log Retention (Days)") { ApplicationArea = All; }
                field("Alert Email Recipients"; Rec."Alert Email Recipients") { ApplicationArea = All; }
                field("Verbose Logging"; Rec."Verbose Logging") { ApplicationArea = All; }
            }

            group(Advanced)
            {
                Caption = 'Advanced';

                field("Email Scenario"; Rec."Email Scenario")
                {
                    ApplicationArea = All;
                    ToolTip = 'Email scenario used for approval emails and failure alerts. Assign an email account to this scenario in Email Scenario Assignment, otherwise sending fails.';
                }
                field("Email Max Lines"; Rec."Email Max Lines")
                {
                    ApplicationArea = All;
                    ToolTip = 'Maximum document lines listed in an approval email; the rest are summarised as a count. Keep equal to the Teams card cap so both channels show the same lines.';
                }
                field("Payload Max Lines"; Rec."Payload Max Lines")
                {
                    ApplicationArea = All;
                    ToolTip = 'Maximum document lines included in the payload sent to Azure when Include Document Lines is on.';
                }
                field("Send Dev Tunnel Header"; Rec."Send Dev Tunnel Header")
                {
                    ApplicationArea = All;
                    ToolTip = 'Sends X-Tunnel-Skip-AntiPhishing-Page on every request so a Microsoft dev tunnel forwards it instead of returning an HTML warning page. Harmless against a real Azure Function App; can be switched off in production.';
                }
            }

            group(Diagnostics)
            {
                Caption = 'Diagnostics';
                Editable = false;

                field("Last Dispatch At"; Rec."Last Dispatch At") { ApplicationArea = All; }
                field("Last Error"; Rec."Last Error") { ApplicationArea = All; }
                field(PendingCount; PendingCount)
                {
                    ApplicationArea = All;
                    Caption = 'Rows Waiting';

                    trigger OnDrillDown()
                    begin
                        OpenOutbox(true);
                    end;
                }
                field(FailedCount; FailedCount)
                {
                    ApplicationArea = All;
                    Caption = 'Rows Failed';
                    StyleExpr = FailedStyle;

                    trigger OnDrillDown()
                    begin
                        OpenOutbox(false);
                    end;
                }
            }
        }
    }

    actions
    {
        area(Processing)
        {
            group(Operations)
            {
                Caption = 'Operations';

                action(TestConnection)
                {
                    ApplicationArea = All;
                    Caption = 'Test Connection';
                    Image = Approve;
                    ToolTip = 'Checks dispatch readiness first, then calls the health endpoint. A green result here means a real dispatch will work, not merely that the URL responds.';

                    trigger OnAction()
                    var
                        HttpClientCU: Codeunit "PN Approval Http Client";
                    begin
                        // Readiness FIRST. The health probe only proves the URL
                        // and credentials work; it says nothing about the
                        // signing secret, which a real dispatch also needs.
                        // Passing here while a real send fails is exactly the
                        // confusion worth avoiding.
                        Rec.TestReadyForDispatch();

                        if HttpClientCU.TryHealthCheck() then
                            Message(ConnectionOkMsg, HttpClientCU.GetLastHttpStatus())
                        else
                            Error(GetLastErrorText());
                    end;
                }

                action(GenerateSigningSecret)
                {
                    ApplicationArea = All;
                    Caption = 'Generate Signing Secret';
                    Image = CreateDocument;
                    ToolTip = 'Generates a random secret and stores it. Use this only when starting from nothing - if the Azure Function already has a value, paste that into the Signing Secret field instead.';

                    trigger OnAction()
                    var
                        Generated: Text;
                    begin
                        Generated :=
                            DelChr(Format(CreateGuid(), 0, 4), '=', '{}-') +
                            DelChr(Format(CreateGuid(), 0, 4), '=', '{}-');

                        Rec.SetSigningSecret(Generated);
                        CurrPage.Update(false);

                        RefreshStoredIndicators();

                        if SigningSecretStored then
                            Message(GeneratedSecretMsg, Generated)
                        else
                            Error(StoreFailedErr);
                    end;
                }

                action(ClearSecrets)
                {
                    ApplicationArea = All;
                    Caption = 'Clear All Secrets';
                    Image = Delete;
                    ToolTip = 'Removes every stored secret from Isolated Storage. Use when rotating credentials or handing an environment over.';

                    trigger OnAction()
                    begin
                        if not Confirm(ClearSecretsQst, false) then
                            exit;

                        Rec.SetFunctionKey('');
                        Rec.SetSigningSecret('');
                        Rec.SetClientSecret('');
                        CurrPage.Update(false);
                        Message(SecretsClearedMsg);
                    end;
                }

                action(ReconcileSecrets)
                {
                    ApplicationArea = All;
                    Caption = 'Reconcile Secret Flags';
                    Image = Refresh;
                    ToolTip = 'Re-checks Isolated Storage and corrects the Stored indicators. Use after an environment copy or restore, where table data survives but stored secrets may not.';

                    trigger OnAction()
                    begin
                        Rec.ReconcileSecretFlags();
                        RefreshStoredIndicators();
                        CurrPage.Update(false);
                        Message(ReconciledMsg);
                    end;
                }

                action(RefreshToken)
                {
                    ApplicationArea = All;
                    Caption = 'Refresh Access Token';
                    Image = RefreshLines;
                    Visible = ShowEntraFields;
                    ToolTip = 'Discards the cached token and requests a new one. Use after rotating the client secret.';

                    trigger OnAction()
                    var
                        OAuthMgt: Codeunit "PN Approval OAuth Mgt.";
                    begin
                        OAuthMgt.ForceRefresh();
                        CurrPage.Update(false);
                        Message(TokenRefreshedMsg, Rec."Token Expires At");
                    end;
                }

                action(CreateJobQueue)
                {
                    ApplicationArea = All;
                    Caption = 'Create Job Queue Entry';
                    Image = Job;
                    ToolTip = 'Creates the recurring Job Queue Entry that drains the outbox, using Job Queue Minutes Between Runs and Job Queue Max. Attempts, if it does not already exist.';

                    trigger OnAction()
                    var
                        Runner: Codeunit "PN Approval Dispatch Runner";
                    begin
                        Runner.EnsureJobQueueEntry();
                        Message(JobQueueCreatedMsg);
                    end;
                }

                action(RunNow)
                {
                    ApplicationArea = All;
                    Caption = 'Dispatch Now';
                    Image = Start;
                    ToolTip = 'Drains the outbox immediately in this session instead of waiting for the Job Queue.';

                    trigger OnAction()
                    var
                        Runner: Codeunit "PN Approval Dispatch Runner";
                        Sent: Integer;
                    begin
                        Sent := Runner.DrainOutbox();
                        CurrPage.Update(false);
                        Message(DispatchNowMsg, Sent);
                    end;
                }
            }

            group(Navigate)
            {
                Caption = 'Related';

                action(OpenChannelSetup)
                {
                    ApplicationArea = All;
                    Caption = 'Channel Setup';
                    Image = Setup;
                    RunObject = page "PN Approval Channel Setup";
                    ToolTip = 'Choose which channels notifications are sent on. Those switches are global and apply to every approver.';
                }

                action(OpenOutboxAction)
                {
                    ApplicationArea = All;
                    Caption = 'Approval Outbox';
                    Image = Log;
                    RunObject = page "PN Approval Outbox";
                }

                action(OpenIdentities)
                {
                    ApplicationArea = All;
                    Caption = 'Approval User Setup';
                    Image = Users;
                    RunObject = page "Approval User Setup";
                    ToolTip = 'Per-approver settings: mobile number, WhatsApp consent, personal approval ceiling and notification suspension. These used to live on a separate page; they are now on the standard Approval User Setup alongside limits and substitutes.';
                }
            }
        }

        area(Promoted)
        {
            group(Category_Process)
            {
                Caption = 'Process';
                actionref(TestConnection_P; TestConnection) { }
                actionref(RunNow_P; RunNow) { }
                actionref(CreateJobQueue_P; CreateJobQueue) { }
                actionref(OpenChannelSetup_P; OpenChannelSetup) { }
                actionref(OpenOutboxAction_P; OpenOutboxAction) { }
            }
        }
    }

    var
        // Never table fields. Held in memory for one round trip and cleared
        // the moment the value reaches Isolated Storage.
        FunctionKeyInput: Text;
        SigningSecretInput: Text;
        ClientSecretInput: Text;
        ActionTokenInput: Text;
        ActionTokenStored: Boolean;
        ActionTokenStyle: Text;

        // Indicators are page variables, not Rec fields. Reading Rec inside a
        // field OnValidate is unreliable - the framework is mid-validation and
        // runs its own record cycle afterwards, which can discard a refresh.
        // These are computed straight from Isolated Storage, so what you see is
        // what is actually retrievable.
        FunctionKeyStored: Boolean;
        SigningSecretStored: Boolean;
        ClientSecretStored: Boolean;

        ShowEntraFields: Boolean;
        ShowFunctionKey: Boolean;
        PendingCount: Integer;
        FailedCount: Integer;
        FailedStyle: Text;
        SecretExpiryStyle: Text;
        FunctionKeyStyle: Text;
        SigningSecretStyle: Text;
        ClientSecretStyle: Text;

        ConnectionOkMsg: Label 'The dispatch service answered with HTTP %1. Authentication, connectivity and dispatch readiness are all in order.', Comment = '%1 = status code';
        TokenRefreshedMsg: Label 'A new access token was obtained. It is valid until %1.', Comment = '%1 = expiry';
        JobQueueCreatedMsg: Label 'The Job Queue Entry is in place and set to Ready.';
        DispatchNowMsg: Label '%1 rows were dispatched.', Comment = '%1 = count';
        GeneratedSecretMsg: Label 'Copy this value into the Azure Function setting Dispatch__SigningSecret now. It will not be shown again.\\%1', Comment = '%1 = generated secret';
        ChangeLogReminderMsg: Label 'This control depends on the Change Log. Switch on change logging for table %1 and fields %2 (Bank Change Table No. and Bank Change Field No. Filter on this page), otherwise the check will always pass and the gate will do nothing.', Comment = '%1 = table no., %2 = field no. filter';
        StoreFailedErr: Label 'The value could not be written to Isolated Storage. Check that you have permission to modify this setup, and that you are in the intended company.';
        ClearSecretsQst: Label 'Remove the function key, signing secret and client secret from Isolated Storage?';
        SecretsClearedMsg: Label 'All stored secrets have been removed.';
        ReconciledMsg: Label 'The Stored indicators now reflect what is actually in Isolated Storage.';

    trigger OnOpenPage()
    begin
        Rec.GetSetup();
    end;

    trigger OnAfterGetCurrRecord()
    begin
        RefreshVisibility();
        RefreshCounts();
    end;

    // ------------------------------------------------------------------
    //  Secret capture
    //
    //  Each of these stores the value, verifies the Boolean flipped, then
    //  blanks the input. Verifying rather than assuming is the point: the
    //  earlier failure was a write that silently did nothing.
    // ------------------------------------------------------------------
    local procedure StoreFunctionKey()
    begin
        if FunctionKeyInput = '' then
            exit;

        Rec.SetFunctionKey(Trim(FunctionKeyInput));
        FunctionKeyInput := '';

        // Verify against storage itself, not against the record. No
        // CurrPage.Update here: calling it mid-validation is what left the
        // indicator stale even though the write had succeeded.
        RefreshStoredIndicators();

        if not FunctionKeyStored then
            Error(StoreFailedErr);

        // Repaint so the Stored indicator reflects reality straight away.
        // Safe here because the indicators are read from Isolated Storage
        // rather than from Rec, so nothing depends on the framework's own
        // record cycle having finished.
        CurrPage.Update(false);
    end;

    local procedure StoreSigningSecret()
    begin
        if SigningSecretInput = '' then
            exit;

        Rec.SetSigningSecret(Trim(SigningSecretInput));
        SigningSecretInput := '';

        RefreshStoredIndicators();

        if not SigningSecretStored then
            Error(StoreFailedErr);

        // Repaint so the Stored indicator reflects reality straight away.
        // Safe here because the indicators are read from Isolated Storage
        // rather than from Rec, so nothing depends on the framework's own
        // record cycle having finished.
        CurrPage.Update(false);
    end;

    local procedure StoreActionTokenSecret()
    begin
        if ActionTokenInput = '' then
            exit;

        Rec.SetActionTokenSecret(Trim(ActionTokenInput));
        ActionTokenInput := '';

        RefreshStoredIndicators();

        if not ActionTokenStored then
            Error(StoreFailedErr);

        CurrPage.Update(false);
    end;

    local procedure StoreClientSecret()
    begin
        if ClientSecretInput = '' then
            exit;

        Rec.SetClientSecret(Trim(ClientSecretInput));
        ClientSecretInput := '';

        RefreshStoredIndicators();

        if not ClientSecretStored then
            Error(StoreFailedErr);

        // Repaint so the Stored indicator reflects reality straight away.
        // Safe here because the indicators are read from Isolated Storage
        // rather than from Rec, so nothing depends on the framework's own
        // record cycle having finished.
        CurrPage.Update(false);
    end;

    /// <summary>
    /// Strips surrounding whitespace, including a tab or newline picked up by a
    /// paste. Those are invisible on screen but break the HMAC comparison on
    /// the Azure side, which then presents as a bare 401 with no explanation.
    /// </summary>
    local procedure Trim(Value: Text): Text
    var
        TrimChars: Text;
    begin
        // Built by index assignment: AL treats a Char as numeric when
        // concatenated, so ' ' + Tab would try to add an Integer to a Text.
        TrimChars := '    ';
        TrimChars[1] := ' ';
        TrimChars[2] := 9;
        TrimChars[3] := 10;
        TrimChars[4] := 13;

        exit(DelChr(Value, '<>', TrimChars));
    end;

    /// <summary>
    /// Reads Isolated Storage directly. The Boolean on the record says what we
    /// intended to write; this says what is actually there. When those two
    /// disagree - after an environment copy, say - this is the honest one.
    /// </summary>
    local procedure RefreshStoredIndicators()
    begin
        FunctionKeyStored := Rec.GetFunctionKey() <> '';
        SigningSecretStored := Rec.GetSigningSecret() <> '';
        ClientSecretStored := Rec.GetClientSecret() <> '';
        ActionTokenStored := Rec.GetActionTokenSecret() <> '';
        ActionTokenStyle := StoredStyle(ActionTokenStored);

        FunctionKeyStyle := StoredStyle(FunctionKeyStored);
        SigningSecretStyle := StoredStyle(SigningSecretStored);
        ClientSecretStyle := StoredStyle(ClientSecretStored);
    end;

    local procedure RefreshVisibility()
    begin
        ShowEntraFields := Rec."Auth Mode" in [
            Rec."Auth Mode"::"OAuth2 Client Credentials",
            Rec."Auth Mode"::Both];

        ShowFunctionKey := Rec."Auth Mode" in [
            Rec."Auth Mode"::"Function Key",
            Rec."Auth Mode"::Both];

        RefreshStoredIndicators();

        SecretExpiryStyle := 'Standard';
        if Rec."Client Secret Expiry Date" <> 0D then
            if Rec."Client Secret Expiry Date" <= Today() + Rec."Secret Expiry Warning (Days)" then
                SecretExpiryStyle := 'Unfavorable';
    end;

    local procedure StoredStyle(IsSet: Boolean): Text
    begin
        if IsSet then
            exit('Favorable');
        exit('Unfavorable');
    end;

    local procedure RefreshCounts()
    var
        Outbox: Record "PN Approval Outbox";
    begin
        Outbox.SetFilter(Status, '%1|%2',
            "PN Approval Outbox Status"::Pending,
            "PN Approval Outbox Status"::Retrying);
        PendingCount := Outbox.Count();

        Outbox.Reset();
        Outbox.SetRange(Status, "PN Approval Outbox Status"::Failed);
        FailedCount := Outbox.Count();

        if FailedCount > 0 then
            FailedStyle := 'Unfavorable'
        else
            FailedStyle := 'Favorable';
    end;

    local procedure OpenOutbox(ShowWaiting: Boolean)
    var
        Outbox: Record "PN Approval Outbox";
    begin
        if ShowWaiting then
            Outbox.SetFilter(Status, '%1|%2',
                "PN Approval Outbox Status"::Pending,
                "PN Approval Outbox Status"::Retrying)
        else
            Outbox.SetRange(Status, "PN Approval Outbox Status"::Failed);

        Page.Run(Page::"PN Approval Outbox", Outbox);
    end;
}
