// Two permission sets, because two very different people need this extension.
//
//  PN APPROVAL ADMIN  - finance/IT administrators: setup, secrets, outbox.
//  PN APPROVAL SVC    - the integration service account. Deliberately narrower:
//                       it needs to read and execute, and to touch approval
//                       entries through the standard framework, but it has no
//                       business editing setup or reading secrets.
permissionset 50100 "PN Approval Admin"
{
    Caption = 'PulseNet Approval Bridge - Admin';
    Assignable = true;
    Permissions =
        tabledata "PN Approval Integration Setup" = RIMD,
        tabledata "User Setup" = RIM,
        tabledata "PN Approval Outbox" = RIMD,
        table "PN Approval Integration Setup" = X,
        table "PN Approval Outbox" = X,
        page "PN Approval Integration Setup" = X,
        page "PN Approval Outbox" = X,
        page "PN Approval Channel Setup" = X,
        page "PN Approval Diagnostics" = X,
        page "PN Approval Entries API" = X,
        page "PN Approver Identity API" = X,
        codeunit "PN Approval Event Subscriber" = X,
        codeunit "PN Approval Payload Builder" = X,
        codeunit "PN Approval Dispatch Runner" = X,
        codeunit "PN Approval Http Client" = X,
        codeunit "PN Approval OAuth Mgt." = X,
        codeunit "PN Approval Action Token" = X,
        codeunit "PN Approval Email Sender" = X,
        codeunit "PN Approval Action Handler" = X;
}

permissionset 50101 "PN Approval Service"
{
    Caption = 'PulseNet Approval Bridge - Service Account';
    Assignable = true;
    Permissions =
        tabledata "PN Approval Integration Setup" = R,
        tabledata "User Setup" = RIM,
        tabledata "PN Approval Outbox" = RM,
        table "PN Approval Outbox" = X,
        page "PN Approval Entries API" = X,
        page "PN Approver Identity API" = X,
        codeunit "PN Approval Action Handler" = X,
        codeunit "PN Approval Dispatch Runner" = X;
}
