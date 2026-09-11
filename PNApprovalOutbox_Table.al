// =========================================================================
//  PN Approval Outbox
// =========================================================================
//
//  WHY THIS TABLE EXISTS
//
//  Business Central blocks the AL session until an outbound HTTP call
//  finishes. Calling Teams or an Azure Function from inside the approval
//  transaction would put a network round-trip on the critical path of a user
//  clicking "Send Approval Request", and a channel outage would surface to
//  that user as a posting failure.
//
//  Worse, it would be wrong even when it worked. If the surrounding
//  transaction later rolls back, the approval never happened - but the
//  notification has already gone out and cannot be recalled.
//
//  So the event subscriber does one thing: it inserts a row here, in the same
//  transaction as the Approval Entry. The two commit together or not at all.
//  A separate Job Queue session drains the table and does the network work,
//  where a failure is a retry rather than a user-visible error.
//
//  This is the transactional outbox pattern. The properties that matter:
//    * atomicity  - the intent to notify is committed with the approval
//    * durability - a row survives a service restart, a failover, a redeploy
//    * at-least-once delivery with an idempotency key, so the receiver can
//      safely discard duplicates
//    * visibility - a failed dispatch is a row a human can see and retry
// =========================================================================
table 50101 "PN Approval Outbox"
{
    Caption = 'Approval Dispatch Outbox';
    DataClassification = CustomerContent;
    DrillDownPageId = "PN Approval Outbox";
    LookupPageId = "PN Approval Outbox";

    fields
    {
        field(1; "Entry No."; Integer)
        {
            Caption = 'Entry No.';
            AutoIncrement = true;
            Editable = false;
        }

        // ---------------------------------------------------------------
        //  What happened
        // ---------------------------------------------------------------
        field(10; "Event Type"; Enum "PN Approval Event Type")
        {
            Caption = 'Event Type';
            Editable = false;
        }
        field(11; "Approval Entry No."; Integer)
        {
            Caption = 'Approval Entry No.';
            Editable = false;
            TableRelation = "Approval Entry"."Entry No.";
            ToolTip = 'The native Approval Entry this dispatch relates to. This, not the document number, is the correlation key - a document can have several open entries in a multi-level chain.';
        }
        field(12; "Record ID to Approve"; RecordId)
        {
            Caption = 'Record ID to Approve';
            Editable = false;
            DataClassification = CustomerContent;
        }
        field(13; "Table ID"; Integer)
        {
            Caption = 'Source Table ID';
            Editable = false;
        }
        field(14; "Document Type"; Enum "Approval Document Type")
        {
            Caption = 'Document Type';
            Editable = false;
        }
        field(15; "Document No."; Code[20])
        {
            Caption = 'Document No.';
            Editable = false;
        }
        field(16; "Sequence No."; Integer)
        {
            Caption = 'Approval Sequence No.';
            Editable = false;
            ToolTip = 'Position of this approver in the chain. Sequence 1 is the first approver; higher numbers are notified only after the previous level approves.';
        }

        // ---------------------------------------------------------------
        //  Who has to act
        // ---------------------------------------------------------------
        field(20; "Approver User ID"; Code[50])
        {
            Caption = 'Approver User ID';
            Editable = false;
            TableRelation = User."User Name";
        }
        field(21; "Approver User Security ID"; Guid)
        {
            Caption = 'Approver User Security ID';
            Editable = false;
            ToolTip = 'The stable identity key. Invoice approvers are Business Central users, not employees, so User Security ID - not Employee No. - is what channel preferences and Entra lookups hang off.';
        }
        field(22; "Sender User ID"; Code[50])
        {
            Caption = 'Sender User ID';
            Editable = false;
        }

        // ---------------------------------------------------------------
        //  Money
        // ---------------------------------------------------------------
        field(30; Amount; Decimal)
        {
            Caption = 'Amount';
            Editable = false;
            AutoFormatType = 1;
            AutoFormatExpression = "Currency Code";
        }
        field(31; "Amount (LCY)"; Decimal)
        {
            Caption = 'Amount (LCY)';
            Editable = false;
            AutoFormatType = 1;
        }
        field(32; "Currency Code"; Code[10])
        {
            Caption = 'Currency Code';
            Editable = false;
            TableRelation = Currency;
        }
        field(33; "High Value"; Boolean)
        {
            Caption = 'High Value';
            Editable = false;
            ToolTip = 'Set when the amount reaches the high value threshold. The Azure Function must not render one-tap approve buttons for these; it sends a notify-only card with a deep link so the approver signs in.';
        }
        field(34; "Bank Details Changed"; Boolean)
        {
            Caption = 'Vendor Bank Details Changed';
            Editable = false;
            ToolTip = 'Set when the vendor bank account changed after the invoice was created. Fast-path approval is suppressed and full review forced.';
        }

        // ---------------------------------------------------------------
        //  Dispatch state machine
        // ---------------------------------------------------------------
        field(50; Status; Enum "PN Approval Outbox Status")
        {
            Caption = 'Status';
            Editable = false;
        }
        field(51; "Attempt Count"; Integer)
        {
            Caption = 'Attempt Count';
            Editable = false;
        }
        field(52; "Next Attempt At"; DateTime)
        {
            Caption = 'Next Attempt At';
            Editable = false;
            ToolTip = 'Rows are only picked up once this moment has passed. Exponential backoff writes this field.';
        }
        field(53; "Created At"; DateTime)
        {
            Caption = 'Created At';
            Editable = false;
        }
        field(54; "Sent At"; DateTime)
        {
            Caption = 'Sent At';
            Editable = false;
        }
        field(55; "Idempotency Key"; Guid)
        {
            Caption = 'Idempotency Key';
            Editable = false;
            ToolTip = 'Sent as a header on every attempt, including retries. The Azure Function keys its deduplication store on this value, so a retry after a timeout cannot produce a second notification.';
        }
        field(56; "Last Error"; Text[250])
        {
            Caption = 'Last Error';
            Editable = false;
        }
        field(57; "Last HTTP Status"; Integer)
        {
            Caption = 'Last HTTP Status';
            Editable = false;
        }
        field(58; "Last Duration (ms)"; Integer)
        {
            Caption = 'Last Duration (ms)';
            Editable = false;
        }
        field(59; "Correlation ID"; Guid)
        {
            Caption = 'Correlation ID';
            Editable = false;
            ToolTip = 'Echoed back by the Azure Function and written into Application Insights on both sides, so one identifier traces a request end to end.';
        }

        // ---------------------------------------------------------------
        //  Diagnostics - only populated when Verbose Logging is on
        // ---------------------------------------------------------------
        field(70; "Request Body"; Blob)
        {
            Caption = 'Request Body';
            DataClassification = CustomerContent;
        }
        field(71; "Response Body"; Blob)
        {
            Caption = 'Response Body';
            DataClassification = CustomerContent;
        }

        // ---------------------------------------------------------------
        //  Phase 2 - channel correlation, written back by the callback API
        // ---------------------------------------------------------------
        field(80; "Delivered Channel"; Enum "PN Approval Channel")
        {
            Caption = 'Delivered Channel';
            Editable = false;
        }
        field(81; "Channel Message ID"; Text[100])
        {
            Caption = 'Channel Message ID';
            Editable = false;
            ToolTip = 'Identifier of the card or message the channel created. Needed to update it in place once the approval is decided.';
        }
    }

    keys
    {
        key(PK; "Entry No.") { Clustered = true; }

        // The drain query. Status first, then the due time, so the runner can
        // seek straight to the work without scanning the whole table.
        key(Drain; Status, "Next Attempt At") { }

        // Used to detect a duplicate event for the same approval entry, and to
        // find the original dispatch when a decision comes back in phase 2.
        key(ByApprovalEntry; "Approval Entry No.", "Event Type") { }

        key(ByDocument; "Table ID", "Document Type", "Document No.") { }
    }

    fieldgroups
    {
        fieldgroup(DropDown; "Entry No.", "Document No.", "Approver User ID", Status) { }
        fieldgroup(Brick; "Document No.", "Approver User ID", "Amount (LCY)", Status) { }
    }

    trigger OnInsert()
    begin
        if IsNullGuid("Idempotency Key") then
            "Idempotency Key" := CreateGuid();
        if IsNullGuid("Correlation ID") then
            "Correlation ID" := CreateGuid();
        if "Created At" = 0DT then
            "Created At" := CurrentDateTime();
        if "Next Attempt At" = 0DT then
            "Next Attempt At" := CurrentDateTime();
    end;

    /// <summary>
    /// Records a failed attempt and schedules the next one with exponential
    /// backoff. Once Max Attempts is reached the row goes to Failed and stops
    /// consuming Job Queue time - a human decides what happens next.
    /// </summary>
    procedure RegisterFailure(ErrorText: Text; HttpStatus: Integer)
    var
        Setup: Record "PN Approval Integration Setup";
        DelaySeconds: Integer;
    begin
        Setup.GetSetup();

        "Attempt Count" += 1;
        "Last Error" := CopyStr(ErrorText, 1, MaxStrLen("Last Error"));
        "Last HTTP Status" := HttpStatus;

        if "Attempt Count" >= Setup."Max Attempts" then begin
            Status := Status::Failed;
            "Next Attempt At" := 0DT;
        end else begin
            Status := Status::Retrying;
            // 30s, 60s, 120s, 240s ... capped so a long outage does not push
            // the next attempt weeks into the future.
            DelaySeconds := Setup."Retry Base Delay (Sec.)" * Power2("Attempt Count" - 1);
            if DelaySeconds > 3600 then
                DelaySeconds := 3600;
            "Next Attempt At" := CurrentDateTime() + (DelaySeconds * 1000);
        end;

        Modify(true);
    end;

    procedure RegisterSuccess(HttpStatus: Integer; DurationMs: Integer)
    begin
        Status := Status::Sent;
        "Sent At" := CurrentDateTime();
        "Last HTTP Status" := HttpStatus;
        "Last Duration (ms)" := DurationMs;
        "Last Error" := '';
        Modify(true);
    end;

    /// <summary>Puts a Failed row back in the queue for one more try.</summary>
    procedure ResetForRetry()
    begin
        Status := Status::Pending;
        "Attempt Count" := 0;
        "Next Attempt At" := CurrentDateTime();
        "Last Error" := '';
        "Last HTTP Status" := 0;
        Modify(true);
    end;

    procedure SetRequestBody(Body: Text)
    var
        OutStr: OutStream;
    begin
        Clear("Request Body");
        "Request Body".CreateOutStream(OutStr, TextEncoding::UTF8);
        OutStr.WriteText(Body);
    end;

    procedure GetRequestBody() Body: Text
    var
        InStr: InStream;
    begin
        CalcFields("Request Body");
        if not "Request Body".HasValue() then
            exit('');
        "Request Body".CreateInStream(InStr, TextEncoding::UTF8);
        InStr.ReadText(Body);
    end;

    procedure SetResponseBody(Body: Text)
    var
        OutStr: OutStream;
    begin
        Clear("Response Body");
        "Response Body".CreateOutStream(OutStr, TextEncoding::UTF8);
        OutStr.WriteText(CopyStr(Body, 1, 30000));
    end;

    procedure GetResponseBody() Body: Text
    var
        InStr: InStream;
    begin
        CalcFields("Response Body");
        if not "Response Body".HasValue() then
            exit('');
        "Response Body".CreateInStream(InStr, TextEncoding::UTF8);
        InStr.ReadText(Body);
    end;

    // Integer power of two. Written out rather than using Power() because that
    // returns a Decimal and the rounding noise is not worth the round trip.
    local procedure Power2(Exponent: Integer): Integer
    var
        Result: Integer;
        i: Integer;
    begin
        Result := 1;
        if Exponent > 10 then
            Exponent := 10;
        for i := 1 to Exponent do
            Result := Result * 2;
        exit(Result);
    end;
}
