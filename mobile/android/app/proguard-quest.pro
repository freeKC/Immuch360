# R8 rules of the quest flavour only (productFlavors.quest in build.gradle), added to proguard-rules.pro: what they
# allow does not reach the phone flavour, whose dependencies keep their warnings.

##---------------Begin: LiteRT (depth model of the AI relief) ----------
# The JNI library of LiteRT finds TensorType, its Layout and ElementType, TensorBufferRequirements and LiteRtException
# by name and builds them from native code, which R8 cannot see: the classes of its API keep their names and members.
# Its deployment package (AiPackModelProvider, Play for On-device AI) is not kept: build.gradle leaves out the Play
# library it needs, and the app never calls it.
-keep class com.google.ai.edge.litert.* { *; }
-dontwarn com.google.android.play.core.aipacks.**
-dontwarn com.google.android.gms.tasks.**
##---------------End: LiteRT ----------
