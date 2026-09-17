// =========================================================================
//  PN Approval Entries API   [PHASE 2]
// =========================================================================
//
//  OData v4 surface the Azure Function calls when an approver taps a button.
//
//  URL shape:
//    GET  /api/pulsenet/approvals/v1.0/companies({companyId})/pnApprovalEntries
//    POST .../pnApprovalEntries({systemId})/Microsoft.NAV.approve
//
//  The bound actions are [ServiceEnabled], so they appear as OData actions
//  rather than needing a SOAP codeunit web service.
//
//  AUTHENTICATION: Entra ID (OAuth 2.0) service-to-service only. Basic auth
//  and web service access keys are gone from BC SaaS. The Function's app
//  registration needs API.ReadWrite.All on Dynamics 365 Business Central, and
//  the resulting service user must hold Approval Administrator.
// =========================================================================
page 50100 "PN Approval Entries API"
{
    Caption = 'Approval Entries API';
    PageType = API;
    APIPublisher = 'pulsenet';
    APIGroup = 'approvals';
    APIVersion = 'v1.0';
    EntityName = 'pnApprovalEntry';
    EntitySetName = 'pnApprovalEntries';
    SourceTable = "Approval Entry";
    DelayedInsert = true;
    Extensible = false;

    // Editable is deliberately NOT set to false.
    //
    // Business Central does not expose bound actions on a non-editable API
    // page. With Editable = false the entity still reads fine over OData, and
    // every action returns:
    //
    //   404  "No HTTP resource was found that matches the request URI"
    //
    // which reads as a missing page rather than a suppressed action, and sends
    // you looking at routes, publishers and API versions instead.
    //
    // The data stays read-only through the three flags below. Those are what
    // actually prevent a caller writing to an Approval Entry; Editable was
    // belt-and-braces that cost the entire callback.
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    ODataKeyFields = SystemId;

    layout
    {
        area(Content)
        {
            repeater(Group)
            {
                field(systemId; Rec.SystemId) { Caption = 'System Id'; }
                field(entryNo; Rec."Entry No.") { Caption = 'Entry No.'; }
                field(tableId; Rec."Table ID") { Caption = 'Table Id'; }
                field(documentType; Rec."Document Type") { Caption = 'Document Type'; }
                field(documentNo; Rec."Document No.") { Caption = 'Document No.'; }
                field(sequenceNo; Rec."Sequence No.") { Caption = 'Sequence No.'; }
                field(approverId; Rec."Approver ID") { Caption = 'Approver Id'; }
                field(senderId; Rec."Sender ID") { Caption = 'Sender Id'; }
                field(status; Rec.Status) { Caption = 'Status'; }
                field(amount; Rec.Amount) { Caption = 'Amount'; }
                field(amountLcy; Rec."Amount (LCY)") { Caption = 'Amount LCY'; }
                field(currencyCode; Rec."Currency Code") { Caption = 'Currency Code'; }
                field(dueDate; Rec."Due Date") { Caption = 'Due Date'; }
                field(lastModifiedDateTime; Rec."Last Date-Time Modified") { Caption = 'Last Modified'; }
            }
        }
    }

    // ------------------------------------------------------------------
    //  Bound actions
    //
    //  Both return a status token rather than throwing, so a duplicate press
    //  gets a readable message instead of a 500.
    //
    //  NEITHER TAKES A WebServiceActionContext, AND THAT IS DELIBERATE.
    //
    //  A bound action that takes `var ActionContext: WebServiceActionContext`
    //  AND returns a value is silently dropped from the OData metadata.
    //  Business Central publishes the page, publishes the other actions, and
    //  simply omits these two - so the entity reads fine and every call to the
    //  action returns:
    //
    //    404  "No HTTP resource was found that matches the request URI"
    //
    //  which reads as a routing fault and sends you checking publishers,
    //  groups and API versions. The only way to see what is wrong is to fetch
    //  $metadata and notice the action is not listed.
    //
    //  ActionContext exists to tell an interactive client to re-fetch the
    //  record after the action runs. The Azure caller does not need that - it
    //  reads the returned status token. The return value is load-bearing;
    //  ActionContext was decoration, and it cost the entire callback.
    //
    //  THE CONTEXT IS PASSED AS PARAMETERS, NOT VIA A PRIOR CALL.
    //
    //  setActionContext and setActionComment still exist, and they publish -
    //  parameters were never the problem. But they are no use to an OData
    //  caller: every OData request creates a FRESH page instance, so a value
    //  set by one call is gone by the next. Calling setActionContext and then
    //  approve would record an approval with no channel, no device and no
    //  comment, and nothing would report a fault.
    //
    //  So everything the audit line needs arrives with the decision itself,
    //  in one call.
    // ------------------------------------------------------------------
    [ServiceEnabled]
    procedure approve(channel: Text; device: Text; correlationId: Text; comment: Text): Text
    var
        Handler: Codeunit "PN Approval Action Handler";
        ExpectedApprover: Code[50];
        ExpectedAmount: Decimal;
    begin
        // The EXPECTED approver and amount come from the outbox row, which
        // froze them when the notification was sent - never from Rec, which
        // holds the values as they are NOW.
        //
        // Comparing a live value against itself is not a guard. It passes
        // every time, including on the invoice that was edited from 40,000 to
        // 400,000 after the card went out, which is the exact case guard 3
        // exists to catch.
        FindOutboxSnapshot(ExpectedApprover, ExpectedAmount);

        exit(Handler.Approve(
            Rec."Entry No.",
            ExpectedApprover,
            ExpectedAmount,
            channel,
            device,
            correlationId,
            comment));
    end;

    [ServiceEnabled]
    procedure reject(channel: Text; device: Text; correlationId: Text; comment: Text): Text
    var
        Handler: Codeunit "PN Approval Action Handler";
        ExpectedApprover: Code[50];
        ExpectedAmount: Decimal;
    begin
        // The EXPECTED approver and amount come from the outbox row, which
        // froze them when the notification was sent - never from Rec, which
        // holds the values as they are NOW.
        //
        // Comparing a live value against itself is not a guard. It passes
        // every time, including on the invoice that was edited from 40,000 to
        // 400,000 after the card went out, which is the exact case guard 3
        // exists to catch.
        FindOutboxSnapshot(ExpectedApprover, ExpectedAmount);

        exit(Handler.Reject(
            Rec."Entry No.",
            ExpectedApprover,
            ExpectedAmount,
            channel,
            device,
            correlationId,
            comment));
    end;

    // Context supplied by the caller as OData action parameters. Kept as page
    // variables because AL bound actions take their parameters this way.
    var
        ExpectedApproverUserId: Code[50];
        ExpectedAmountLcy: Decimal;
        ActionChannel: Text;
        ActionDevice: Text;
        ActionCorrelationId: Text;
        ActionComment: Text;

    /// <summary>
    /// Reads the approver and amount as they stood when the notification was
    /// sent, from the most recent dispatched outbox row for this entry.
    ///
    /// Returns blanks when there is no row, which makes the handler's guards
    /// skip rather than fail. That is the right default: an approval raised
    /// before this extension was installed, or dispatched manually, should
    /// still be approvable - it simply carries no snapshot to compare against.
    /// </summary>
    local procedure FindOutboxSnapshot(var ExpectedApprover: Code[50]; var ExpectedAmount: Decimal)
    var
        Outbox: Record "PN Approval Outbox";
    begin
        Clear(ExpectedApprover);
        Clear(ExpectedAmount);

        Outbox.SetRange("Approval Entry No.", Rec."Entry No.");
        Outbox.SetRange("Event Type", Outbox."Event Type"::Requested);
        if not Outbox.FindLast() then
            exit;

        ExpectedApprover := Outbox."Approver User ID";
        ExpectedAmount := Outbox."Amount (LCY)";
    end;

    [ServiceEnabled]
    procedure setActionContext(approverUserId: Code[50]; amountLcy: Decimal; channel: Text; device: Text; correlationId: Text): Text
    begin
        ExpectedApproverUserId := approverUserId;
        ExpectedAmountLcy := amountLcy;
        ActionChannel := channel;
        ActionDevice := device;
        ActionCorrelationId := correlationId;
        exit('OK');
    end;

    /// <summary>
    /// The approver's own words, written to an Approval Comment Line before
    /// the decision is recorded.
    ///
    /// Separate from setActionContext so an existing caller that does not send
    /// a comment keeps working unchanged.
    /// </summary>
    [ServiceEnabled]
    procedure setActionComment(comment: Text): Text
    begin
        ActionComment := comment;
        exit('OK');
    end;
}
