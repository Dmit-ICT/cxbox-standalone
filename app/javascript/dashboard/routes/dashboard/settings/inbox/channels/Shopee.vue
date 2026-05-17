<script>
import { mapGetters } from 'vuex';
import { useVuelidate } from '@vuelidate/core';
import { useAlert } from 'dashboard/composables';
import { required } from '@vuelidate/validators';
import router from '../../../../index';
import PageHeader from '../../SettingsSubPageHeader.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';

const SHOP_COUNTRIES = [
  { value: 'thailand', labelKey: 'THAILAND' },
  { value: 'singapore', labelKey: 'SINGAPORE' },
  { value: 'malaysia', labelKey: 'MALAYSIA' },
  { value: 'indonesia', labelKey: 'INDONESIA' },
  { value: 'vietnam', labelKey: 'VIETNAM' },
  { value: 'philippines', labelKey: 'PHILIPPINES' },
  { value: 'taiwan', labelKey: 'TAIWAN' },
  { value: 'brazil', labelKey: 'BRAZIL' },
  { value: 'mexico', labelKey: 'MEXICO' },
  { value: 'colombia', labelKey: 'COLOMBIA' },
  { value: 'chile', labelKey: 'CHILE' },
  { value: 'chinese_mainland', labelKey: 'CHINESE_MAINLAND' },
];

export default {
  components: {
    PageHeader,
    NextButton,
  },
  setup() {
    return { v$: useVuelidate() };
  },
  data() {
    return {
      channelName: '',
      appPartnerId: '',
      appPartnerKey: '',
      shopCountry: '',
      shopCountries: SHOP_COUNTRIES,
    };
  },
  computed: {
    ...mapGetters({
      uiFlags: 'inboxes/getUIFlags',
    }),
  },
  validations: {
    channelName: { required },
    appPartnerId: { required },
    appPartnerKey: { required },
    shopCountry: { required },
  },
  methods: {
    async createChannel() {
      this.v$.$touch();
      if (this.v$.$invalid) {
        return;
      }

      try {
        const shopeeChannel = await this.$store.dispatch(
          'inboxes/createChannel',
          {
            name: this.channelName?.trim(),
            channel: {
              type: 'shopee',
              app_partner_id: this.appPartnerId,
              app_partner_key: this.appPartnerKey,
              shop_country: this.shopCountry,
            },
          }
        );

        router.replace({
          name: 'settings_inboxes_add_agents',
          params: {
            page: 'new',
            inbox_id: shopeeChannel.id,
          },
        });
      } catch (error) {
        useAlert(this.$t('INBOX_MGMT.ADD.SHOPEE_CHANNEL.API.ERROR_MESSAGE'));
      }
    },
  },
};
</script>

<template>
  <div class="h-full w-full p-6 col-span-6">
    <PageHeader
      :header-title="$t('INBOX_MGMT.ADD.SHOPEE_CHANNEL.TITLE')"
      :header-content="$t('INBOX_MGMT.ADD.SHOPEE_CHANNEL.DESC')"
    />
    <form
      class="flex flex-wrap flex-col mx-0"
      @submit.prevent="createChannel()"
    >
      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.channelName.$error }">
          {{ $t('INBOX_MGMT.ADD.SHOPEE_CHANNEL.CHANNEL_NAME.LABEL') }}
          <input
            v-model="channelName"
            type="text"
            :placeholder="
              $t('INBOX_MGMT.ADD.SHOPEE_CHANNEL.CHANNEL_NAME.PLACEHOLDER')
            "
            @blur="v$.channelName.$touch"
          />
          <span v-if="v$.channelName.$error" class="message">{{
            $t('INBOX_MGMT.ADD.SHOPEE_CHANNEL.CHANNEL_NAME.ERROR')
          }}</span>
        </label>
      </div>

      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.appPartnerId.$error }">
          {{ $t('INBOX_MGMT.ADD.SHOPEE_CHANNEL.APP_PARTNER_ID.LABEL') }}
          <input
            v-model="appPartnerId"
            type="text"
            :placeholder="
              $t('INBOX_MGMT.ADD.SHOPEE_CHANNEL.APP_PARTNER_ID.PLACEHOLDER')
            "
            @blur="v$.appPartnerId.$touch"
          />
        </label>
      </div>

      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.appPartnerKey.$error }">
          {{ $t('INBOX_MGMT.ADD.SHOPEE_CHANNEL.APP_PARTNER_KEY.LABEL') }}
          <input
            v-model="appPartnerKey"
            type="text"
            :placeholder="
              $t('INBOX_MGMT.ADD.SHOPEE_CHANNEL.APP_PARTNER_KEY.PLACEHOLDER')
            "
            @blur="v$.appPartnerKey.$touch"
          />
        </label>
      </div>

      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.shopCountry.$error }">
          {{ $t('INBOX_MGMT.ADD.SHOPEE_CHANNEL.SHOP_COUNTRY.LABEL') }}
          <select v-model="shopCountry" @blur="v$.shopCountry.$touch">
            <option value="" disabled>
              {{ $t('INBOX_MGMT.ADD.SHOPEE_CHANNEL.SHOP_COUNTRY.PLACEHOLDER') }}
            </option>
            <option
              v-for="country in shopCountries"
              :key="country.value"
              :value="country.value"
            >
              {{
                $t(
                  `INBOX_MGMT.ADD.SHOPEE_CHANNEL.SHOP_COUNTRY.OPTIONS.${country.labelKey}`
                )
              }}
            </option>
          </select>
        </label>
      </div>

      <div class="w-full mt-4">
        <NextButton
          :is-loading="uiFlags.isCreating"
          type="submit"
          solid
          blue
          :label="$t('INBOX_MGMT.ADD.SHOPEE_CHANNEL.SUBMIT_BUTTON')"
        />
      </div>
    </form>
  </div>
</template>
