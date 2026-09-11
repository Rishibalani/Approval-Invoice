// Operational view of the outbox. This page is the reason the pattern is worth
// the extra table: when a notification does not arrive, somebody can see why,
// see the exact payload, and retry it - without reading a log stream.
page 50103 "PN Approval Outbox"
{
    Caption = 'Approval Dispatch Outbox';
    PageType = List;
    ApplicationArea = All;
    UsageCategory = Lists;
    SourceTable = "PN Approval Outbox";
    SourceTableView = sorting("Entry No.") order(descending);
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;

    layout
    {
        area(Content)
        {
            repeater(Rows)
            {
                field("Entry No."; Rec."Entry No.") { ApplicationArea = All; }
                field(Status; Rec.Status)
                {
                    ApplicationArea = All;
                    StyleExpr = StatusStyle;
                }
                field("Event Type"; Rec."Event Type") { ApplicationArea = All; }
                field("Document Type"; Rec."Document Type") { ApplicationArea = All; }
                field("Document No."; Rec."Document No.") { ApplicationArea = All; }
                field("Approver User ID"; Rec."Approver User ID") { ApplicationArea = All; }
                field("Sequence No."; Rec."Sequence No.") { ApplicationArea = All; }
                field("Amount (LCY)"; Rec."Amount (LCY)") { ApplicationArea = All; }
                field("High Value"; Rec."High Value")
                {
                    ApplicationArea = All;
                    StyleExpr = HighValueStyle;
                }
                field("Bank Details Changed"; Rec."Bank Details Changed")
                {
                    ApplicationArea = All;
                    StyleExpr = BankChangeStyle;
                }
                field("Attempt Count"; Rec."Attempt Count") { ApplicationArea = All; }
                field("Next Attempt At"; Rec."Next Attempt At") { ApplicationArea = All; }
                field("Created At"; Rec."Created At") { ApplicationArea = All; }
                field("Sent At"; Rec."Sent At") { ApplicationArea = All; Visible = false; }
                field("Last HTTP Status"; Rec."Last HTTP Status") { ApplicationArea = All; }
                field("Last Duration (ms)"; Rec."Last Duration (ms)") { ApplicationArea = All; Visible = false; }
                field("Last Error"; Rec."Last Error") { ApplicationArea = All; }
                field("Approval Entry No."; Rec."Approval Entry No.") { ApplicationArea = All; Visible = false; }
                field("Idempotency Key"; Rec."Idempotency Key") { ApplicationArea = All; Visible = false; }
                field("Correlation ID"; Rec."Correlation ID") { ApplicationArea = All; Visible = false; }
                field("Delivered Channel"; Rec."Delivered Channel") { ApplicationArea = All; }
                field("Channel Message ID"; Rec."Channel Message ID") { ApplicationArea = All; Visible = false; }
            }
        }
    }

    actions
    {
        area(Processing)
        {
            action(RetryRow)
            {
                ApplicationArea = All;
                Caption = 'Retry';
                Image = Restore;
                ToolTip = 'Resets the attempt count and puts the selected rows back in the queue for the next Job Queue run.';

                trigger OnAction()
                var
                    Selected: Record "PN Approval Outbox";
                begin
                    CurrPage.SetSelectionFilter(Selected);
                    if Selected.FindSet() then
                        repeat
                            Selected.ResetForRetry();
                        until Selected.Next() = 0;
                    CurrPage.Update(false);
                end;
            }

            action(SkipRow)
            {
                ApplicationArea = All;
                Caption = 'Mark as Skipped';
                Image = Cancel;
                ToolTip = 'Retires the selected rows without dispatching them. Use when an approval has already been handled in Business Central and the notification is no longer wanted.';

                trigger OnAction()
                var
                    Selected: Record "PN Approval Outbox";
                begin
                    if not Confirm(SkipConfirmQst, false) then
                        exit;
                    CurrPage.SetSelectionFilter(Selected);
                    if Selected.FindSet() then
                        repeat
                            Selected.Status := Selected.Status::Skipped;
                            Selected.Modify(true);
                        until Selected.Next() = 0;
                    CurrPage.Update(false);
                end;
            }

            action(ViewPayload)
            {
                ApplicationArea = All;
                Caption = 'View Payload';
                Image = ViewDetails;
                ToolTip = 'Shows the exact JSON that was sent. Only populated when Verbose Logging is switched on in setup.';

                trigger OnAction()
                var
                    Body: Text;
                begin
                    Body := Rec.GetRequestBody();
                    if Body = '' then
                        Message(NoPayloadMsg)
                    else
                        Message(Body);
                end;
            }

            action(ViewResponse)
            {
                ApplicationArea = All;
                Caption = 'View Response';
                Image = Log;

                trigger OnAction()
                var
                    Body: Text;
                begin
                    Body := Rec.GetResponseBody();
                    if Body = '' then
                        Message(NoPayloadMsg)
                    else
                        Message(Body);
                end;
            }

            action(DispatchNow)
            {
                ApplicationArea = All;
                Caption = 'Dispatch Now';
                Image = Start;

                trigger OnAction()
                var
                    Runner: Codeunit "PN Approval Dispatch Runner";
                begin
                    Runner.DrainOutbox();
                    CurrPage.Update(false);
                end;
            }

            action(ShowApprovalEntry)
            {
                ApplicationArea = All;
                Caption = 'Approval Entry';
                Image = Approvals;

                trigger OnAction()
                var
                    ApprovalEntry: Record "Approval Entry";
                begin
                    if not ApprovalEntry.Get(Rec."Approval Entry No.") then
                        Error(NoApprovalEntryErr);
                    ApprovalEntry.SetRecFilter();
                    Page.Run(Page::"Approval Entries", ApprovalEntry);
                end;
            }
        }

        area(Promoted)
        {
            group(Category_Process)
            {
                Caption = 'Process';
                actionref(RetryRow_P; RetryRow) { }
                actionref(DispatchNow_P; DispatchNow) { }
                actionref(ViewPayload_P; ViewPayload) { }
                actionref(SkipRow_P; SkipRow) { }
            }
        }
    }

    var
        StatusStyle: Text;
        HighValueStyle: Text;
        BankChangeStyle: Text;
        SkipConfirmQst: Label 'Skip the selected rows? They will never be dispatched.';
        NoPayloadMsg: Label 'Nothing was captured for this row. Switch on Verbose Logging in Approval Integration Setup and retry the row to capture it.';
        NoApprovalEntryErr: Label 'The related Approval Entry no longer exists.';

    trigger OnAfterGetRecord()
    begin
        case Rec.Status of
            Rec.Status::Sent:
                StatusStyle := 'Favorable';
            Rec.Status::Failed:
                StatusStyle := 'Unfavorable';
            Rec.Status::Retrying, Rec.Status::Sending:
                StatusStyle := 'Ambiguous';
            else
                StatusStyle := 'Standard';
        end;

        if Rec."High Value" then
            HighValueStyle := 'Attention'
        else
            HighValueStyle := 'Standard';

        if Rec."Bank Details Changed" then
            BankChangeStyle := 'Unfavorable'
        else
            BankChangeStyle := 'Standard';
    end;
}
