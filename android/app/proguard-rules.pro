# Keep generic type signatures needed by Gson TypeToken in some plugins.
-keepattributes Signature,InnerClasses,EnclosingMethod,*Annotation*

# flutter_local_notifications (avoid stripping generic info used for scheduled notification cache)
-keep class com.dexterous.flutterlocalnotifications.** { *; }

