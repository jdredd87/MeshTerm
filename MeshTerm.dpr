program MeshTerm;

{ MeshTerm - a small Windows terminal for Meshtastic LoRa radios
  (tested with a Seeed XIAO nRF52840 + Wio-SX1262 kit, firmware 2.6). }

{$R 'MeshTerm.res'}

uses
  Vcl.Forms,
  Meshtastic.Proto in 'Meshtastic.Proto.pas',
  Meshtastic.Port in 'Meshtastic.Port.pas',
  Meshtastic.Transport in 'Meshtastic.Transport.pas',
  Meshtastic.Ble in 'Meshtastic.Ble.pas',
  Meshtastic.Client in 'Meshtastic.Client.pas',
  Meshtastic.Mqtt in 'Meshtastic.Mqtt.pas',
  Meshtastic.Crypto in 'Meshtastic.Crypto.pas',
  QrCode in 'QrCode.pas',
  MapView in 'MapView.pas',
  MainForm in 'MainForm.pas';

begin
  {$IFDEF DEBUG}ReportMemoryLeaksOnShutdown := True;{$ENDIF}
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.Title := 'MeshTerm';
  Application.CreateForm(TMainForm, frmMain);
  Application.Run;
end.
