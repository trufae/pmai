package org.mai.pocketmai;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import java.security.KeyStore;
import java.security.SecureRandom;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/** A stable identity seed encrypted by a non-exportable Android Keystore key. */
public final class ForwirohIdentity {
    public static synchronized String load(Context context) throws Exception {
        String alias = "pmai.forwiroh.identity";
        KeyStore keys = KeyStore.getInstance("AndroidKeyStore");
        keys.load(null);
        SharedPreferences prefs = context.getSharedPreferences(alias, Context.MODE_PRIVATE);
        String saved = prefs.getString("seed", null);
        if (!keys.containsAlias(alias)) {
            if (saved != null) throw new IllegalStateException("Forwiroh identity key is unavailable");
            KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
            generator.init(new KeyGenParameterSpec.Builder(alias,
                KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
            generator.generateKey();
        }
        SecretKey key = (SecretKey) keys.getKey(alias, null);
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        byte[] seed;
        if (saved != null) {
            byte[] iv = Base64.decode(prefs.getString("iv", ""), Base64.NO_WRAP);
            cipher.init(Cipher.DECRYPT_MODE, key, new GCMParameterSpec(128, iv));
            seed = cipher.doFinal(Base64.decode(saved, Base64.NO_WRAP));
            if (seed.length != 32) throw new IllegalStateException("Invalid Forwiroh identity");
        } else {
            seed = new byte[32];
            new SecureRandom().nextBytes(seed);
            cipher.init(Cipher.ENCRYPT_MODE, key);
            byte[] encrypted = cipher.doFinal(seed);
            if (!prefs.edit().putString("iv", Base64.encodeToString(cipher.getIV(), Base64.NO_WRAP))
                .putString("seed", Base64.encodeToString(encrypted, Base64.NO_WRAP)).commit()) {
                throw new IllegalStateException("Cannot save Forwiroh identity");
            }
        }
        return Base64.encodeToString(seed, Base64.NO_WRAP);
    }
}
