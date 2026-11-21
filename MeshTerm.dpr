program MeshTerm;

{ MeshTerm for Windows and Android (FireMonkey). Shares the Meshtastic units
  (protocol, client, transports) with the VCL MeshTerm.exe. }

uses
  System.StartUpCopy,
  FMX.Forms,
  Meshtastic.Proto in 'Meshtastic.Proto.pas',
  Meshtastic.Crypto in 'Meshtastic.Crypto.pas',
  Meshtastic.Port in 'Meshtastic.Port.pas',
  Meshtastic.Usb.Android in 'Meshtastic.Usb.Android.pas',
  Meshtastic.Transport in 'Meshtastic.Transport.pas',
  Meshtastic.Ble in 'Meshtastic.Ble.pas',
  Meshtastic.Client in 'Meshtastic.Client.pas',
  Meshtastic.Mqtt in 'Meshtastic.Mqtt.pas',
  QrCode in 'QrCode.pas',
  Meshtastic.Settings in 'Meshtastic.Settings.pas',
  Meshtastic.NodeView in 'Meshtastic.NodeView.pas',
  Meshtastic.Bridge in 'Meshtastic.Bridge.pas',
  Meshtastic.Places in 'Meshtastic.Places.pas',
  MapViewX in 'MapViewX.pas',
  FmxSheet in 'FmxSheet.pas',
  Meshtastic.Demo in 'Meshtastic.Demo.pas',
  MainFormX in 'MainFormX.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TMainFormX, MainFormXInstance);
  Application.Run;
end.
