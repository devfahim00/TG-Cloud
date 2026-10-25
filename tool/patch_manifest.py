import re
p = 'android/app/src/main/AndroidManifest.xml'
s = open(p, encoding='utf-8').read()
perms = '''<uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32"/>
    <uses-permission android:name="android.permission.READ_MEDIA_IMAGES"/>
    <uses-permission android:name="android.permission.READ_MEDIA_VIDEO"/>
    <uses-permission android:name="android.permission.ACCESS_MEDIA_LOCATION"/>
    '''
if 'READ_MEDIA_IMAGES' not in s:
    s = s.replace('<application', perms + '<application', 1)
s = re.sub(r'android:label="[^"]*"', 'android:label="TG Cloud"', s, count=1)
open(p, 'w', encoding='utf-8').write(s)
print('manifest patched')
