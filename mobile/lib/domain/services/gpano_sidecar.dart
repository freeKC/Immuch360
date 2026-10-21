// The XMP sidecar that tells the Immich server a photo is a 360° sphere when the photo itself does not say so: the
// spheres of DJI drones carry no GPano tags, so the server shows them flat in its web app and its shared links. Sent
// beside the unchanged photo in the same upload (the sidecarData part of POST /assets), it is merged by the server over
// the tags of the photo, which flags the asset as equirectangular; the bytes of the photo, its checksum and the
// detection of duplicates stay as they are.

/// The name of the sidecar of the photo named [photoName], as the server expects one: the name of the photo with .xmp
/// after it ("DJI_0042.JPG.xmp")
String gpanoSidecarName(String photoName) => '$photoName.xmp';

/// An XMP packet declaring a full equirectangular sphere of [width] x [height] pixels in GPano tags: the projection,
/// the panorama viewer, and the full and cropped sizes (the whole frame), as Google's Photo Sphere XMP writes them.
/// About 900 bytes.
String gpanoSidecarXmp({required int width, required int height}) {
  if (width <= 0 || height <= 0) {
    throw ArgumentError('The frame of a sphere has a size: $width x $height');
  }
  return '''<?xpacket begin="\uFEFF" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Immuch360">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:GPano="http://ns.google.com/photos/1.0/panorama/"
    GPano:ProjectionType="equirectangular"
    GPano:UsePanoramaViewer="True"
    GPano:FullPanoWidthPixels="$width"
    GPano:FullPanoHeightPixels="$height"
    GPano:CroppedAreaImageWidthPixels="$width"
    GPano:CroppedAreaImageHeightPixels="$height"
    GPano:CroppedAreaLeftPixels="0"
    GPano:CroppedAreaTopPixels="0"/>
 </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>
''';
}
