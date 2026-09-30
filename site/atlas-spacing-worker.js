importScripts('atlas-spacing.js');
onmessage=function(event) {
  try {
    var spacing=atlasPointSpacing(event.data.x,event.data.y);
    postMessage({spacing:spacing},[spacing.buffer]);
  } catch(error) { postMessage({error:error.message}); }
};
