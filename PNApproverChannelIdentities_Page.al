page 50101 "PN Approver Channel Identities"
{
    Caption = 'Approver Channel Identities';
    PageType = List;
    ApplicationArea = All;
    UsageCategory = Lists;
    SourceTable = "PN Approver Channel Identity";
    CardPageId = "PN Approver Channel Identity";

    layout
    {
        area(Content)
        {
            repeater(Rows)
            {
                field("User ID"; Rec."User ID") { ApplicationArea = All; }
                field("Full Name"; Rec."Full Name") { ApplicationArea = All; }
                field("Authentication Email"; Rec."Authentication Email") { ApplicationArea = All; }
                field("Personal High Value Threshold"; Rec."Personal High Value Threshold") { ApplicationArea = All; }
                field(Suspended; Rec.Suspended)
                {
                    ApplicationArea = All;
                    StyleExpr = SuspendedStyle;
                }
                field("Consent Given"; Rec."Consent Given") { ApplicationArea = All; }
                field("User Security ID"; Rec."User Security ID") { ApplicationArea = All; Visible = false; }
            }
        }
    }

    actions
    {
        area(Processing)
        {
            action(MatchEmployees)
            {
                ApplicationArea = All;
                Caption = 'Match Employee Records';
                Image = Employee;
                ToolTip = 'Attempts to link each approver to an employee by matching company email. A heuristic - check the results and correct any that are wrong, since Business Central has no standard user-to-employee link.';

                trigger OnAction()
                var
                    Identity: Record "PN Approver Channel Identity";
                    Matched: Integer;
                    Scanned: Integer;
                begin
                    if Identity.FindSet() then
                        repeat
                            Scanned += 1;
                            if Identity.TryMatchEmployee() then
                                Matched += 1;
                        until Identity.Next() = 0;

                    CurrPage.Update(false);
                    Message(MatchedMsg, Scanned, Matched);
                end;
            }

            action(ImportApprovers)
            {
                ApplicationArea = All;
                Caption = 'Import From Approval User Setup';
                Image = Import;
                ToolTip = 'Creates an identity row for every user named in Approval User Setup who does not have one yet, so nobody in the approval hierarchy is silently missed.';

                trigger OnAction()
                var
                    ApprovalUserSetup: Record "User Setup";
                    Identity: Record "PN Approver Channel Identity";
                    User: Record User;
                    Created: Integer;
                begin
                    if ApprovalUserSetup.FindSet() then
                        repeat
                            User.SetRange("User Name", ApprovalUserSetup."User ID");
                            if User.FindFirst() then
                                if not Identity.Get(User."User Security ID") then
                                    if Identity.GetOrCreate(User."User Security ID") then
                                        Created += 1;
                        until ApprovalUserSetup.Next() = 0;
                    CurrPage.Update(false);
                    Message(ImportedMsg, Created);
                end;
            }
        }
        area(Promoted)
        {
            group(Category_Process)
            {
                Caption = 'Process';
                actionref(ImportApprovers_P; ImportApprovers) { }
                actionref(MatchEmployees_P; MatchEmployees) { }
            }
        }
    }

    var
        SuspendedStyle: Text;
        ImportedMsg: Label '%1 approver identity records were created.', Comment = '%1 = count';
        MatchedMsg: Label 'Scanned %1 approvers and linked %2 to an employee record.', Comment = '%1 = scanned, %2 = matched';

    trigger OnAfterGetRecord()
    begin
        if Rec.Suspended then
            SuspendedStyle := 'Unfavorable'
        else
            SuspendedStyle := 'Standard';
    end;
}
