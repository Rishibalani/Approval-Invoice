// =========================================================================
//  PN Approval Install
// =========================================================================
//
//  Makes sure the setup record exists in every company on install, so its
//  InitValue defaults (timing, retry, OAuth authority, bank-change fields and
//  so on) are in place before anything reads them.
//
//  A reinstall can find a row left behind by an earlier version. That row is
//  brought up to date the same way the upgrade codeunit does it, then the
//  upgrade tag is set so the work is not repeated.
// =========================================================================
codeunit 50109 "PN Approval Install"
{
    Subtype = Install;
    Access = Internal;
    Permissions = tabledata "PN Approval Integration Setup" = rim;

    trigger OnInstallAppPerCompany()
    var
        Setup: Record "PN Approval Integration Setup";
        UpgradeTag: Codeunit "Upgrade Tag";
    begin
        if Setup.Get() then
            // Existing row: fill any configuration field it predates.
            // Idempotent - a populated row is left as it is.
            Setup.ApplyConfigDefaultsToExistingRow()
        else
            // New row: Init() inside GetSetup applies every InitValue.
            Setup.GetSetup();

        if not UpgradeTag.HasUpgradeTag(Setup.GetConfigFieldsUpgradeTag()) then
            UpgradeTag.SetUpgradeTag(Setup.GetConfigFieldsUpgradeTag());
    end;
}
