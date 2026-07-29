// Plasma runs this when an application-launcher applet is first created under
// the UmbraOS global theme. This is the native system-integrator mechanism for
// baking applet defaults into a look-and-feel package.
applet.currentConfigGroup = ["General"];
applet.writeConfig("icon", "umbra-application-dark");
applet.reloadConfig();
