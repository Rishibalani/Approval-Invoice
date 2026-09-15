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
    Editable = false;
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
    //  Bound actions. Both return a status token rather than throwing, so a
    //  duplicate tap gets a friendly message instead of a 500.
    // ------------------------------------------------------------------
    [ServiceEnabled]
    procedure approve(var ActionContext: WebServiceActionContext): Text
    var
        Handler: Codeunit "PN Approval Action Handler";
    begin
        ActionContext.SetObjectType(ObjectType::Page);
        ActionContext.SetObjectId(Page::"PN Approval Entries API");
        ActionContext.AddEntityKey(Rec.FieldNo(SystemId), Rec.SystemId);
        ActionContext.SetResultCode(WebServiceActionResultCode::Get);

        exit(Handler.Approve(
            Rec."Entry No.",
            ExpectedApproverUserId,
            ExpectedAmountLcy,
            ActionChannel,
            ActionDevice,
            ActionCorrelationId,
            ActionComment));
    end;

    [ServiceEnabled]
    procedure reject(var ActionContext: WebServiceActionContext): Text
    var
        Handler: Codeunit "PN Approval Action Handler";
    begin
        ActionContext.SetObjectType(ObjectType::Page);
        ActionContext.SetObjectId(Page::"PN Approval Entries API");
        ActionContext.AddEntityKey(Rec.FieldNo(SystemId), Rec.SystemId);
        ActionContext.SetResultCode(WebServiceActionResultCode::Get);

        exit(Handler.Reject(
            Rec."Entry No.",
            ExpectedApproverUserId,
            ExpectedAmountLcy,
            ActionChannel,
            ActionDevice,
            ActionCorrelationId,
            ActionComment));
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
